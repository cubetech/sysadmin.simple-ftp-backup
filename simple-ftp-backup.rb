#!/usr/bin/env ruby

# Add local directory to LOAD_PATH
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__))

require 'net/ftp'
require 'settings'
require 'rubygems'
require 'sequel'
require 'date'

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
    ftp = Net::FTP.new(FTP_HOST)
    ftp.login(FTP_USER, FTP_PASS)
    return ftp
  end
end

def ftp_close(ftp)
  begin
    path = ftp.pwd
    ftp.close
    return path
  end
end

# Initial setup
timestamp = Time.now.strftime("%Y%m%d-%H%M")
full_tmp_path = File.join(TMP_BACKUP_PATH, "simple-s3-backup-" << timestamp)
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
path = ftp_close(ftp)

print "\nConnected to FTP and selected bucket\n\n"

# Create tmp directory
Dir.mkdirs full_tmp_path

# Perform MySQL backup of all databases or specific ones
if defined?(MYSQL_ALL or MYSQL_DBS)

  # Build an array of databases to backup
  if defined?(MYSQL_ALL)
    connection = Sequel.mysql nil, :user => MYSQL_USER, :password => MYSQL_PASS, :host => 'localhost', :encoding => 'utf8'
    @databases = connection['show databases;'].collect { |db| db[:Database] }
  elsif defined?(MYSQL_DBS)
    @databases = MYSQL_DBS
  end

  # Fail if there are no databases to backup
  raise "Error: There are no db's to backup." if @databases.empty?

  ftp = ftp_open
  ftp.chdir(path)

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
    system("#{MYSQLDUMP_CMD} -u #{MYSQL_USER} #{password_param} --single-transaction --add-drop-table --add-locks --create-options --disable-keys --extended-insert --quick #{db} | #{GZIP_CMD} -#{GZIP_STRENGTH} -c > #{full_tmp_path}/#{db_filename}")

    # Upload file to FTP
    folderlist = ftp.list()
    if !folderlist.any?{|dir| dir.match(/\s#{MYSQLPATH}$/)}
      ftp.mkdir(MYSQLPATH)
    end
    ftp.putbinaryfile("#{full_tmp_path}/#{db_filename}", "#{MYSQLPATH}/#{db_filename}")

  end
  path = ftp_close(ftp)
  print "MySQL backup finished\n"
end


# Perform MongoDB backups
if defined?(MONGO_DBS)

  # Create dump dir
  mdb_dump_dir = File.join(full_tmp_path, "mdbs")
  Dir.mkdirs(mdb_dump_dir)

  ftp = ftp_open
  ftp.chdir(path)
  # Create dumps and upload them to ftp
  MONGO_DBS.each do |mdb|

    # Create dump and archive
    mdb_filename = "mdb-#{mdb}.tgz"
    system("#{MONGODUMP_CMD} -h #{MONGO_HOST} -d #{mdb} -o #{mdb_dump_dir} && cd #{mdb_dump_dir}/#{mdb} && #{TAR_CMD} -czf #{full_tmp_path}/#{mdb_filename} .")

    # Upload file to FTP
    folderlist = ftp.list()
    if !folderlist.any?{|dir| dir.match(/\s#{MONGOPATH}$/)}
      ftp.mkdir(MONGOPATH)
    end
    ftp.putbinaryfile("#{full_tmp_path}/#{mdb_filename}", "#{MONGOPATH}/#{mdb_filename}")

  end
  path = ftp_close(ftp)
  print "MongoDB backup finished\n"
  system("rm -rf #{mdb_dump_dir}")
end

# Perform directory backups
if defined?(DIRECTORIES)
  DIRECTORIES.each do |name, dir|

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
    system("cd #{dir} && #{TAR_CMD} #{excludes} -czf #{full_tmp_path}/#{dir_filename} .")
    
    # Create file path on server if needed
    ftp = ftp_open
    ftp.chdir(path)
    folderlist = ftp.list()
    if !folderlist.any?{|dir| dir.match(/\s#{FILEPATH}$/)}
      ftp.mkdir(FILEPATH)
    end
    path = ftp_close(ftp)

    # Split and upload file to FTP
    filesize = File.size("#{full_tmp_path}/#{dir_filename}").to_f / 1024000
    if filesize > SPLIT_SIZE
      system("split -d -b #{SPLIT_SIZE}m #{full_tmp_path}/#{dir_filename} #{full_tmp_path}/#{dir_filename}.")
      system("rm -rf #{full_tmp_path}/#{dir_filename}")
      Dir.glob("#{full_tmp_path}/#{dir_filename}.*") do |item|
        basename = File.basename(item)
        ftp = ftp_open
        ftp.chdir(path)
        ftp.putbinaryfile("#{item}", "#{FILEPATH}/#{basename}")
        path = ftp_close(ftp)
      end
    else
      ftp = ftp_open
      ftp.chdir(path)
      ftp.putbinaryfile("#{full_tmp_path}/#{dir_filename}", "#{FILEPATH}/#{dir_filename}")
      path = ftp_close(ftp)
    end
  end
  print "Directories backup finished\n"
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

    # Check if FTP dir exists
    ftp = ftp_open
    ftp.chdir(path)
    folderlist = ftp.list()
    if !folderlist.any?{|dir| dir.match(/\s#{FILEPATH}$/)}
      ftp.mkdir(FILEPATH)
    end
    path = ftp_close(ftp)

    # Create archive & copy to S3
    system("cd #{files_tmp_path} && #{TAR_CMD} -czf #{full_tmp_path}/#{files_filename} *")
    ftp = ftp_open
    ftp.chdir(path)
    ftp.putbinaryfile("#{full_tmp_path}/#{files_filename}", "#{FILEPATH}/#{files_filename}")
    path = ftp_close(ftp)

    # Remove the temporary directory for the files
    system("rm -rf #{files_tmp_path}")
  end
  print "File backup finished\n"
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
    print "Old backup #{file} deleted.\n"
  end
end
ftp_close(ftp)

print "\nBackup finished.\n"

exit
