#!/usr/bin/env ruby

# Add local directory to LOAD_PATH
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__))

require 'net/ftp'
require 'settings'
require 'FileUtils'
require 'sequel'

# Initial setup
timestamp = Time.now.strftime("%Y%m%d-%H%M")
full_tmp_path = File.join(TMP_BACKUP_PATH, "simple-s3-backup-" << timestamp)

# Find/create the backup bucket
ftp = Net::FTP.new(FTP_HOST)
ftp.login(FTP_USER, FTP_PASS)

if defined?(FTP_BASEPATH) and FTP_BASEPATH!=nil and FTP_BASEPATH!=""
  folderlist = ftp.list(FTP_BASEPATH)
else
  folderlist = ftp.list("/")
end
ftp.mkdir("#{FTP_BASEPATH}#{FTP_FOLDER}") if !folderlist.any?{|dir| dir.match(/\s#{FTP_FOLDER}$/)}
ftp.chdir("#{FTP_BASEPATH}#{FTP_FOLDER}")
folderlist = ftp.list(".")

# Create tmp directory
FileUtils.mkdir_p full_tmp_path

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
    # Upload file to S3
    if !folderlist.any?{|dir| dir.match(/\smysqldb$/)}
      ftp.mkdir("mysqldb")
    end
    ftp.putbinaryfile(db_filename, "#{full_tmp_path}/#{db_filename}")
  end
end
exit


# Perform MongoDB backups
if defined?(MONGO_DBS)
  mdb_dump_dir = File.join(full_tmp_path, "mdbs")
  FileUtils.mkdir_p mdb_dump_dir
  MONGO_DBS.each do |mdb|
    mdb_filename = "mdb-#{mdb}.tgz"
    system("#{MONGODUMP_CMD} -h #{MONGO_HOST} -d #{mdb} -o #{mdb_dump_dir} && cd #{mdb_dump_dir}/#{mdb} && #{TAR_CMD} -czf #{full_tmp_path}/#{mdb_filename} .")
    S3Object.store("mongodb/#{timestamp}/#{mdb_filename}", open("#{full_tmp_path}/#{mdb_filename}"), S3_BUCKET)
  end
  FileUtils.remove_dir mdb_dump_dir
end

# Perform directory backups
if defined?(DIRECTORIES)
  DIRECTORIES.each do |name, dir|
    dir_filename = "dir-#{name}.tgz"
    excludes = ""
    DIRECTORIES_EXCLUDE.each do |de|
      excludes += "--exclude=\"#{de}\" "
    end
    system("cd #{dir} && #{TAR_CMD} #{excludes} -czf #{full_tmp_path}/#{dir_filename} .")
    filesize = File.size("#{full_tmp_path}/#{dir_filename}").to_f / 1024000
    if filesize > 4000
      system("split -d -b 3900m #{full_tmp_path}/#{dir_filename} #{full_tmp_path}/#{dir_filename}.")
      system("rm -rf #{full_tmp_path}/#{dir_filename}")
      Dir.glob("#{full_tmp_path}/#{dir_filename}.*") do |item|
        basename = File.basename(item)
        S3Object.store("directories/#{timestamp}/#{basename}", open("#{item}"), S3_BUCKET)
      end
    else
      S3Object.store("directories/#{timestamp}/#{dir_filename}", open("#{full_tmp_path}/#{dir_filename}"), S3_BUCKET)
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
FileUtils.remove_dir full_tmp_path

# Now, clean up unwanted archives
cutoff_date = Time.now.utc.to_i - (DAYS_OF_ARCHIVES * 86400)
bucket.objects.select{ |o| o.last_modified.to_i < cutoff_date }.each do |f|
  S3Object.delete(f.key, S3_BUCKET)
end
