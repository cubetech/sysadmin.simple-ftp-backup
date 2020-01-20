#!/usr/bin/env ruby

# Add local directory to LOAD_PATH
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__))

# Define some variables
$backupsize = 0
$logmessage = ""
$errors = 0
$db_error = false
$dir_error = false
$file_error = false
$ftp_error = false

# Include some standard libs
require 'net/ftp'
require 'net/https'
require 'socket'
require 'settings'
require 'rubygems'
require 'date'
require 'base64'
require 'open3'

# Monkey patch
class Object
	def to_sb
		return 'false' if [FalseClass, NilClass].include?(self.class) 
		return 'true' if self.class == TrueClass
		self
	end  
end 

# Dashboard ping
def ping_dashboard(fatal_out = false)
	
	begin
		
		# Push to the dashboard if activated
		if defined?(DASHBOARD) and DASHBOARD == true
			errordata = "db:" + $db_error.to_sb + ",dir:" + $dir_error.to_sb + ",file:" + $file_error.to_sb + ",ftp:" + $ftp_error.to_sb
			if fatal_out == true
				errordata = "fatal:true"
			end
			uri = URI.parse(DASHBOARD_URL)
			request_params = {
				"server" => Socket.gethostname,
				"bucket" => FTP_FOLDER,
				"size" => $backupsize.to_s,
				"errors" => $errors.to_s,
				"output" => Base64.encode64($logmessage),
				"errordata" => errordata
			}
			http = Net::HTTP.new(uri.host, uri.port)
			http.use_ssl = true
			http.verify_mode = OpenSSL::SSL::VERIFY_NONE
			request = Net::HTTP::Post.new(uri.path)
			request.set_form_data(request_params)
			response = http.request(request)
		end

	end
	
end

# Some puts enhancement
def say(message)
	
	begin

		puts message
		$logmessage += message.to_s
		
	end
	
end

# Include additional libs
begin
	require 'sequel'
	require 'filesize'
rescue Exception => e
	say("ERROR: Some includes are not found. Sure you have the gems installed?")
  $errors += 1
  ping_dashboard(true)
	exit 1
end

# Trapping the user
trap "SIGINT" do
  say("\nExiting. ATTENTION: The backup is not finished!")
  $errors += 1
  ping_dashboard(true)
  exit 130
end

# Function for creating recursive directories
class Dir
  def self.mkdirs(p)
     return if File.exists?(p)
     dir, file = File.split(p)
     Dir.mkdirs(dir) if !File.exists?(dir)
     Dir.mkdir(p)
  end
end

# FTP function to remove a nonempty folder
def ftp_remove_all(ftp,file)    
  begin
    ftp.chdir(file)
    ftp.chdir("../")      
    data = ftp.list('-A ' + file)      
    for line in data        
      filename = line.split(/(\s)/)        
      ftp_remove_all(ftp,file + "/" + filename[filename.length-1])        
    end            
    ftp.rmdir(file)
  rescue
    ftp.delete(file)
  end     
end

def ftp_open
  begin
    ftp = Net::FTP.new(FTP_HOST, FTP_USER, FTP_PASS)
    ftp.passive = FTP_PASSIVE
    return ftp
  rescue
  	say("ERROR: FTP connection failed: " + $!.to_s)
		$errors += 1
  	$ftp_error = true
  	ping_dashboard()
  	exit
  end
end

def ftp_close(ftp)
  begin
    path = ftp.pwd
    ftp.close
    return path
  end
end

def ftp_go_upload(path, file)

	begin
		
		basename = File.basename(file)
	
		# Open FTP and check for path existing
	  ftp = ftp_open
	  ftp.chdir(FTP_GROUND_PATH)
	  folderlist = ftp.list()
	  if !folderlist.any?{|dir| dir.match(/\s#{path}$/)}
	    ftp.mkdir(path)
	  end
	  ftp.chdir(path)
	
	  # Split and upload file to FTP
	  baresize = File.size(file)
	  $backupsize += baresize
	  filesize = Filesize.from("#{baresize} B").pretty
	  
	  if (baresize/1024000) > SPLIT_SIZE
	    system("split -d -b #{SPLIT_SIZE}m #{file} #{file}.")
	    system("rm -rf #{file}")
	    Dir.glob("#{file}.*") do |item|
	      uploadname = File.basename(item)
	      ftp.putbinaryfile("#{item}", "#{uploadname}")
	    end
	    texttag = " (splitted)"
	  else
	    ftp.putbinaryfile("#{file}", "#{basename}")
	    texttag = ""
	  end
	  
	  # Close ftp and return status
	  ftp_close(ftp)
	  say("Archive #{basename} uploaded (Size: #{filesize})#{texttag}")

	rescue

		# Rescue (hopefully...)
		say("ERROR: Archive #{basename} is not fully uploaded! (#{$!})")
		$errors += 1
		$ftp_error = true

	end

end

# Initial setup
timestamp = Time.now.strftime("%Y%m%d-%H%M")
full_tmp_path = File.join(TMP_BACKUP_PATH, "simple-ftp-backup-" << timestamp)
if defined?(DATEPATH) and DATEPATH!=false
  basepath = "#{FTP_BASEPATH}/#{FTP_FOLDER}/#{timestamp}"
  clean_basepath = "/#{FTP_BASEPATH}/#{FTP_FOLDER}"
elsif defined?(FTP_BASEPATH) and FTP_BASEPATH!=nil and FTP_BASEPATH!=""
  basepath = "#{FTP_BASEPATH}/#{FTP_FOLDER}"
  clean_basepath = "/#{FTP_BASEPATH}/#{FTP_FOLDER}"
else
  basepath = FTP_FOLDER
  clean_basepath = "/#{FTP_FOLDER}"
end

# Remove double slash
basepath = basepath.squeeze('/').strip

# Find/create the backup bucket
ftp = ftp_open()
flist = basepath.split("/")
flist.each do |folder|
  folderlist = ftp.list()
  ftp.mkdir(folder) if !folderlist.any?{|dir| dir.match(/\s#{folder}$/)}
  ftp.chdir(folder)
end
FTP_GROUND_PATH = ftp.pwd
ftp.close

say("\nConnected to FTP and selected bucket\n")

# Create tmp directory
begin
	Dir.mkdirs full_tmp_path
	say('Created temporary path: ' + full_tmp_path)
rescue
	say('Could not create temporary directory: ' + $!)
	$errors += 1
	ping_dashboard(true)
	exit 1
end

# Perform MySQL backup of all databases or specific ones
if defined?(MYSQL_ALL) or defined?(MYSQL_DBS)

  # Build an array of databases to backup
  @databases = []
  if defined?(MYSQL_ALL)
	  begin
	  	connection = Sequel.mysql2 nil, :user => MYSQL_USER, :password => MYSQL_PASS, :host => 'localhost', :encoding => 'utf8'
	  	@databases = connection['show databases;'].collect { |db| db[:Database] }
		@databases.delete('performance_schema')
		@databases.delete('information_schema')
		@databases.delete('mysql')
	  rescue Exception => e
	  	say('ERROR: MySQL connection not successful: ')
	  	say($!)
	  	$errors += 1
	  	ping_dashboard(true)
	  	exit 1
	  end
  elsif defined?(MYSQL_DBS)
    @databases = MYSQL_DBS
  end

  # Fail if there are no databases to backup
  if @databases.empty?
		say("Error: There are no db's to backup.")
		$errors += 1
    $db_error = true
  end

  @databases.each do |db|

    # Define file name
    db_filename = "db-#{db}-#{timestamp}.sql.gz"

    # Define password parameter
    if defined?(MYSQL_PASS) and MYSQL_PASS!=nil and MYSQL_PASS!=""
      password_param = "-p#{MYSQL_PASS}"
    else
      password_param = ""
    end

    # Perform the mysqldump and compress the output to file
    cmd = "#{MYSQLDUMP_CMD} -u #{MYSQL_USER} #{password_param} --single-transaction --add-drop-table --add-locks --create-options --disable-keys --extended-insert --events --quick #{db} | #{GZIP_CMD} -#{GZIP_STRENGTH} -c > #{full_tmp_path}/#{db_filename}"
    Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
	    while line = stderr.gets
		    say(line)
		    $errors += 1
		    $db_error = true
			end
		end

    # Upload file to FTP
    ftp_go_upload(MYSQLPATH, "#{full_tmp_path}/#{db_filename}")
	    
		# Remove the file
		system("rm -rf #{full_tmp_path}/#{db_filename}")

  end

  say("\nMySQL backup finished\n")

end


# Perform MongoDB backups
if defined?(MONGO_DBS)

  # Create dump dir
  mdb_dump_dir = File.join(full_tmp_path, "mdbs")
  Dir.mkdirs(mdb_dump_dir)

  # Create dumps and upload them to ftp
  MONGO_DBS.each do |mdb|

    # Create dump and archive
    mdb_filename = "mdb-#{mdb}.tgz"
    cmd = "#{MONGODUMP_CMD} -h #{MONGO_HOST} -d #{mdb} -o #{mdb_dump_dir} && #{TAR_CMD} #{tarswitch} #{excludes} -cPf - . | #{GZIP_CMD} -#{GZIP_STRENGTH} -c > #{full_tmp_path}/#{dir_filename}"
    Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
	    while line = stderr.gets
		    say(line)
		    $errors += 1
		    $db_error = true
			end
		end

    # Upload file to FTP
    ftp_go_upload(MONGOPATH, "#{full_tmp_path}/#{mdb_filename}")

	# Remove the file
	system("rm -rf #{full_tmp_path}/#{mdb_filename}")

  end

  say("\nMongoDB backup finished\n")

end

# Perform directory backups
if defined?(DIRECTORIES) and !defined?(ARGV[0])

	# Add symlink tar switch
	tarswitch = ""
	if defined?(SYMLINKS) and SYMLINKS == true
		tarswitch += " --dereference"
	end
	
	# Add ignore failed read option
	if defined?(IGNORE_FAILED_READS) and IGNORE_FAILED_READS == true
		tarswitch += " --ignore-failed-read --warning=none"
	end
	
	# For each list entry do some backups...
	DIRECTORIES.each do |name, dir|
	
		# Check if multiple subdirs backup
		if dir.include? "*"
		
			# Set constant if not sets
			if (defined?(DIRECTORIES_EXCLUDE)).nil?
				DIRECTORIES_EXCLUDE = []
			end
			
			# Go through each dir
			Dir.glob("#{dir}").each do |dirpath|
			
				# Make tar gz name
				dirname = File.basename(dirpath)
				dir_filename = "dir-#{name}-#{dirname}.tgz"
				
				# Get excludes
				excludes = ""
				if defined?(DIRECTORIES_EXCLUDE)
					DIRECTORIES_EXCLUDE.each do |de|
						excludes += "--exclude=\"#{de}\" "
					end
				end
				
				# Hell yeah, make some tgz!!
				cmd = "#{TAR_CMD} #{tarswitch} #{excludes} -cPf - #{dirpath} | #{GZIP_CMD} -#{GZIP_STRENGTH} -c > #{full_tmp_path}/#{dir_filename}"
				Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
					while line = stderr.gets
						say(line)
						$errors += 1
						$dir_error = true
					end
				end
				
				# Upload file to FTP
				ftp_go_upload(FILEPATH, "#{full_tmp_path}/#{dir_filename}")
				
				# Remove the file
				system("rm -rf #{full_tmp_path}/#{dir_filename}")
			
			end
		
		else
		
		# Define file name
			dir_filename = "dir-#{name}.tgz"
			
			# Get excludes
			excludes = ""
			if defined?(DIRECTORIES_EXCLUDE)
				DIRECTORIES_EXCLUDE.each do |de|
					excludes += "--exclude=\"#{de}\" "
				end
			end
			
			# Create archive
			cmd = "#{TAR_CMD} #{tarswitch} #{excludes} -cPf - #{dir} | #{GZIP_CMD} -#{GZIP_STRENGTH} -c > #{full_tmp_path}/#{dir_filename}"
			Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
				while line = stderr.gets
					say(line)
					$errors += 1
					$dir_error = true
				end
			end
			
			# Upload file to FTP
			ftp_go_upload(FILEPATH, "#{full_tmp_path}/#{dir_filename}")
			
			# Remove the file
			system("rm -rf #{full_tmp_path}/#{dir_filename}")
		
		end
	
	end
	
	say("\nDirectories backup finished\n")

end

# Perform single files backups
if defined?(SINGLE_FILES)
  SINGLE_FILES.each do |name, files|

    # Create a directory to collect the files
    files_tmp_path = File.join(full_tmp_path, "#{name}-tmp")
    Dir.mkdirs(files_tmp_path)

    # Filename for files
    files_filename = "files-#{name}.tgz"

    # Copy files to temp directory
    files.each do |file|
      system("cp #{file} #{files_tmp_path}")
    end

    # Create archive
    cmd = "cd #{files_tmp_path} && #{TAR_CMD} #{tarswitch} #{excludes} -cPf - * | #{GZIP_CMD} -#{GZIP_STRENGTH} -c > #{full_tmp_path}/#{dir_filename}"
		Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
	    while line = stderr.gets
		    say(line)
		    $errors += 1
		    $file_error = true
			end
		end

		# Upload file to FTP
    ftp_go_upload(FILEPATH, "#{full_tmp_path}/#{files_filename}")

    # Remove the files
    system("rm -rf #{files_tmp_path} && rm -rf #{full_tmp_path}/#{files_filename}")
    
  end

  say("\nFile backup finished\n")
 
end

# Remove tmp directory
system("rm -rf #{full_tmp_path}")

print "\n"

# Now, clean up unwanted archives
ftp = ftp_open
list = ftp.list("#{clean_basepath}")
list.each do |file|

  # Get file name
  file = file.split(/\s+/).last
  
  # Get dates
  date = DateTime.strptime(file, "%Y%m%d-%H%M")
  limit = DateTime.now - DAYS_OF_ARCHIVES
  
  # Check if deletion is needed, if yes, delete
  if date < limit
    ftp_remove_all(ftp, "#{clean_basepath}/#{file}")
    say("Old backup #{file} deleted.\n")
  end
end
ftp.close

say("\nBackup finished.\n")

ping_dashboard()

exit
