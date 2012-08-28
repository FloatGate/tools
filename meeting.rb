require 'thread'
require 'time'
require 'sinatra'

class Array
	def each_two
		while length >= 2
			yield shift, shift
		end
	end
end

class  Meeting_Stats
	attr_accessor :members, :cur_index, :next_meeting_at, :names, :has_sent_notifier_for_current, :real_cur

	MEM_FILE = ".weekly_meeting_members"
	CONF_FILE = ".weekly_config"

	def initialize 
		parse_member_file
		parse_conf_file
		@lock = Mutex.new
		@cv = ConditionVariable.new
		@holder_confirmed = false
	end

	def next_at w
		@lock.lock
		@next_meeting_at = w
		refresh_conf_file
		@lock.unlock
	end

	def next_maybe 
		n = Time.now
		n += 60*60*24 #advance one day
		n += 60*60*24 until n.wday == 1 #advance until next Monday
		[n.year, n.month, n.day].collect(&:to_s).join '/'
	end

	def next_holder_mail m
		@lock.lock
		n = nil
		for name, mail in @members
			n = name if mail == m
		end
		if n
			@real_cur = n
			refresh_conf_file
		end
		@lock.unlock
	end

	def add_member (n, m)
		n = chomp_the_name n
		@lock.lock
		@names << n
		@names.sort!
		n_nth = @names.index n
		@members[n] = m		
		#adjust the index to advance if the new joined name is in the part which have already hold the meeting
		if n_nth <= @cur_index
			@cur_index += 1
			refresh_conf_file
		end

		refresh_members_file
		@lock.unlock
	end

	def del_member m
		@lock.lock
		who = nil
		for name,mail in @members
			who = name if mail == m
		end
		if who
			nth = @names.index who
			if nth <= @cur_index
				@cur_index -= 1
				refresh_conf_file
			end
			@names.delete who
			refresh_members_file
		end

		@lock.unlock
	end

	def cur_member
		@lock.lock
		n = @names[@cur_index]
		@lock.unlock
		n
	end

	def next_member
		@lock.lock
		n = @names[(@cur_index + 1) % @names.length]
		@lock.unlock
		n
	end

	#send the notifier for current index member
	#this will also update the config file
	def send_notifier
		@lock.lock
		who = @real_cur ? @real_cur : @names[@cur_index]
		mail = @members[who]
		unless @has_sent_notifier_for_current
			send_mail :notify, who, mail
			@has_sent_notifier_for_current = true
			refresh_conf_file
		end
		@lock.unlock

		ask_for_confirm who, mail
	end

	# only for @real_cur changed 
	def resend
		send_mail :notify, @real_cur, @members[@real_cur]
		refresh_conf_file
	end
	
	def recv_confirm_from 
		#name = chomp_the_name name
		@lock.lock
		#who = @names[@cur_index]
		if true #who == name
			@cur_index += 1
			@cur_index %= @names.count
			@holder_confirmed = true
			@has_sent_notifier_for_current = false
			@real_cur = nil
			refresh_conf_file
			@cv.signal
		else
			#name is not what we want
			#TODO
		end			

		@lock.unlock
	end
	
	private 
	def send_mail (type, who, mail)
		str = 'mail -s "Weekly meeting host notice"  -r xxx@xxx.com' + mail
		if type == :notify
			system (str + " < notice")
		else
			system (str + " < confirm")
		end
	end
		
	def refresh_members_file
		File.open(MEM_FILE, "w") do |f|
			@names.each do |n|
				f.write  n+"\n"+@members[n]+"\n"
			end
		end
	end
	
	def refresh_conf_file
		conf = {}
		conf[:index] = @cur_index
		conf[:next_meeting_at] = @next_meeting_at
		conf[:has_sent_notifier_for_current] = @has_sent_notifier_for_current
		conf[:real_cur] = @real_cur
		File.open(CONF_FILE, "w") do |f|
			#puts conf.to_s
			f.write conf.to_s
		end
	end
	
	def parse_member_file
		@members = {}
		@names = []
		
		s = IO.readlines MEM_FILE
		s = s.collect do |x|
				x.chomp!
			end
		s.each_two do |name, mail|
			name = chomp_the_name name
			@members[name] = mail
			@names << name
			#members << {:name => name, :mail => mail}
		end
		@names.sort! 
		#only need for the first time
		refresh_members_file
	end
	
	def  chomp_the_name (n)
		n.chomp!
		n = n.split(/[, ]/).collect { |x| x == "" ? nil : x }
		n = n.compact.collect do |x|
			x = x.downcase.capitalize
			x
		end
		n.join ','
	end
	
	def parse_conf_file
		s = IO.read CONF_FILE
		conf = eval s
		@cur_index = conf[:index]
		@next_meeting_at = conf[:next_meeting_at]
		@has_sent_notifier_for_current = conf[:has_sent_notifier_for_current]
		@real_cur = conf[:real_cur]
		@real_cur = chomp_the_name @real_cur if @real_cur
	end	

	def ask_for_confirm who, mail
		ts = @next_meeting_at.split /\//
		# check at the 12:00 am of the day on which meeting is held
		target_time = Time.local ts[0], ts[1], ts[2], 12
		now = Time.now
		secs = target_time - now
		sleep secs if secs > 0
	
		send_mail :confirm, who, mail

		Thread.new {
			wait_then_run_next_round
		}

		# check at the second day to see whether the target has sent back the confirm
		# if not, he/she will receive the confirm request each day
		secs = 24*60*60  #seconds of one day
		sleep secs
		@lock.lock
		until @holder_confirmed
			@lock.unlock
			sleep secs
			send_mail :confirm, who, mail
		end	
		@holder_confirmed = false
		@lock.unlock
	end

	def wait_then_run_next_round
		@lock.lock
		@cv.wait @lock
		@lock.unlock

		send_notifier
	end

end

stat = Meeting_Stats.new
# this is the logic to handle the mail notification
# the loop logic in inernal
Thread.new {
	stat.send_notifier
}

get "/finish" do
	w = stat.real_cur ? stat.real_cur : stat.cur_member
	s = "<form method='post' action='/confirm'>" + 
		w + ' has finished holding the weekly meeting<br>'  +
		"Please help to confirm the time of next meeting: <input type='text' name='when_next'
		value='" + stat.next_maybe + "'><br>" + 
		"<input type='submit' name='.submit'>
		</form>"
	erb s
end

post "/confirm" do
	#w = stat.cur_member
	stat.recv_confirm_from 
	stat.next_at params[:when_next]
	"Thanks for your effort to hold the weekly meeting"
end

get "/change" do
	w = stat.real_cur ? stat.real_cur : stat.cur_member
	m = stat.members[w]
	at = stat.next_meeting_at
	s = '<form method="post" action="/change_confirm">' +  
		'who will hold for next meeting(using mail address): <input type="text" name="who" value="' + m + '"/> <br>' +
		'when will be the next meeting at(format like 2012/09/03): <input type="text" name="when" value="' + at + '"/> <br>' +
		'new member: <input type="text" name="mem_name" value="name" /> <input type="text" name="mem_mail" value="mail address" /> <br>' +
		'del member: <input type="text" name="del_mem" value="mail_addr"/> <br>' + 
		'<input type="submit" name=".submit"> </form>'
	erb s
end

post "/change_confirm" do
	#puts params
	who = params[:who]
	at = params[:when]
	#cur_who = stat.cur_member
	#cur_at = stat.next_meeting_at
	stat.next_holder_mail who
	stat.next_meeting_at = at

	stat.resend

	mem_name = params[:mem_name]
	mem_mail = params[:mem_mail]
	stat.add_member mem_name, mem_mail if mem_name != "name"

	del_mem = params[:del_mem]
	stat.del_member del_mem if del_mem != "mail_addr"

	"Modification success"
end
