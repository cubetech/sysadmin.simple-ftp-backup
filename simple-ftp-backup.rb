#!/usr/bin/env ruby

# Add local directory to LOAD_PATH
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__))

require 'net/ftp'
require 'settings'
require 'rubygems'
require 'sequel'

class Dir
  def self.mkdirs(p)
     return if File.exists?(p)
     dir, file = File.split(p)
     Dir.mkdirs(dir) if !File.exists?(dir)
     Dir.mkdir(p)
  end
end

# Initial setup
timestamp = Time.now.strftime("%Y%m%d-%H%M")
full_tmp_path = File.join(TMP_BACKUP_PATH, "simple-s3-backup-" << timestamp)
if defined?(DATEPATH) and DATEPATH!=false
  basepath = "#{FTP_BASEPATH}/#{FTP_FOLDER}/#{timestamp}"
elsif defined?(FTP_BASEPATH) and FTP_BASEPATH!=nil and FTP_BASEPATH!=""
  basepath = "#{FTP_BASEPATH}/#{FTP_FOLDER}"
else
  basepath = FTP_FOLDER
end

# Remove double slash
basepath = basepath.squeeze('/').strip

# Find/create the backup bucket
ftp = Net::FTP.new(FTP_HOST)
ftp.login(FTP_USER, FTP_PASS)

flist = basepath.split("/")
flist.each do |folder|
  folderlist = ftp.list()
  ftp.mkdir(folder) if !folderlist.any?{|dir| dir.match(/\s#{folder}$/)}
  ftp.chdir(folder)
end

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

  @databases.each do |db|
    db_filename = "db-#{db}-#{timestamp}.sql.gz"
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
end


# Perform MongoDB backups
if defined?(MONGO_DBS)
  mdb_dump_dir = File.join(full_tmp_path, "mdbs")
  Dir.mkdirs(mdb_dump_dir)
  MONGO_DBS.each do |mdb|
    mdb_filename = "mdb-#{mdb}.tgz"
    system("#{MONGODUMP_CMD} -h #{MONGO_HOST} -d #{mdb} -o #{mdb_dump_dir} && cd #{mdb_dump_dir}/#{mdb} && #{TAR_CMD} -czf #{full_tmp_path}/#{mdb_filename} .")
    S3Object.store("mongodb/#{timestamp}/#{mdb_filename}", open("#{full_tmp_path}/#{mdb_filename}"), S3_BUCKET)
  end
  system("rm -rf #{mdb_dump_dir}")
end

# Perform directory backups
if defined?(DIRECTORIES)
  DIRECTORIES.each do |name, dir|
    dir_filename = "dir-#{name}.tgz"
    excludes = ""
    if defined?(DIRECTORIES_EXCLUDE)
      DIRECTORIES_EXCLUDE.each do |de|
        excludes += "--exclude=\"#{de}\" "
      end
    end
    system("cd #{dir} && #{TAR_CMD} #{excludes} -czf #{full_tmp_path}/#{dir_filename} .")
    # Split and upload file to FTP
    folderlist = ftp.list()
    if !folderlist.any?{|dir| dir.match(/\s#{FILEPATH}$/)}
      ftp.mkdir(FILEPATH)
    end
    filesize = File.size("#{full_tmp_path}/#{dir_filename}").to_f / 1024000
    if filesize > SPLIT_SIZE
      system("split -d -b #{SPLIT_SIZE}m #{full_tmp_path}/#{dir_filename} #{full_tmp_path}/#{dir_filename}.")
      system("rm -rf #{full_tmp_path}/#{dir_filename}")
      Dir.glob("#{full_tmp_path}/#{dir_filename}.*") do |item|
        basename = File.basename(item)
        ftp.putbinaryfile("#{item}", "#{FILEPATH}/#{basename}")
      end
    else
      ftp.putbinaryfile("#{full_tmp_path}/#{dir_filename}", "#{FILEPATH}/#{dir_filename}")
    end
  end
end

# Perform single files backups
if defined?(SINGLE_FILES)
  SINGLE_FILES.each do |name, files|

    # Create a directory to collect the files
    files_tmp_path = File.join(full_tmp_path, "#{name}-tmp")
    FileUtils.mkdir_p files_tmp_path

    # Filename for files
    files_filename = "files-#{name}.tgz"

    # Copy files to temp directory
    FileUtils.cp files, files_tmp_path

    # Create archive & copy to S3
    system("cd #{files_tmp_path} && #{TAR_CMD} -czf #{full_tmp_path}/#{files_filename} .")
    S3Object.store("files/#{timestamp}/#{files_filename}", open("#{full_tmp_path}/#{files_filename}"), S3_BUCKET)

    # Remove the temporary directory for the files
    FileUtils.remove_dir files_tmp_path
  end
end

# Remove tmp directory
system("rm -rf #{full_tmp_path}")

# Now, clean up unwanted archives
#cutoff_date = Time.now.strftime("%Y%m%d-") - (DAYS_OF_ARCHIVES * 86400)
#bucket.objects.select{ |o| o.last_modified.to_i < cutoff_date }.each do |f|
#  S3Object.delete(f.key, S3_BUCKET)
#end
