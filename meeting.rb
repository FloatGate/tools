require 'thread'
require 'time'
require 'sinatra'

class Array
	def each_two
		while self.length >= 2
			a = self.shift
			b = self.shift
			yield a, b
		end
	end
end

class  Meeting_Stats
	attr_accessor :members, :cur_index, :next_meeting_at, :names, :has_sent_notifier_for_current

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
		until n.wday == 1
			n += 60*60*24
		end
		[n.year, n.month, n.day].collect(&:to_s).join '/'
	end

	def add_member (n, m)
		n = chomp_the_name n
		@lock.lock
		@names << n
		@names.sort!
		n_nth = name_index n
		@members[n] = m		
		#adjust the index to advance if the new joined name is in the part which have already hold the meeting
		if n_nth <=@cur_index
			@cur_index += 1
			refresh_conf_file
		end

		refresh_members_file
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
		who = @names[@cur_index]
		mail = @members[who]
		unless @has_sent_notifier_for_current
			send_mail :notify, who, mail
			@has_sent_notifier_for_current = true
			refresh_conf_file
		end
		@lock.unlock

		ask_for_confirm who, mail
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
			refresh_conf_file
			@cv.signal
		else
				#name is what we want
				#TODO
		end			

		@lock.unlock
	end
	
	private 
	def send_mail (type, who, mail)
		str = 'mail -s "Weekly meeting host notice" ' + mail 
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
		File.open(CONF_FILE, "w") do |f|
			puts conf.to_s
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
	#get the index of the meeting members of arg name
	def name_index  name
		for i in (0 .. @names.length)
			if @names[i] == name
				return i
			end
		end
		throw Exception
	end
	
	def  chomp_the_name (n)
		n.chomp!
		n = n.split(/ /).collect do |x|
			x == "" ? nil : x
		end
		n = n.compact.collect do |x|
			x = x.downcase.capitalize
			if x.end_with? ','
				x.slice!(x.length - 1)
			end
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

get "/" do
	w = stat.cur_member
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
