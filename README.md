Simple FTP Backup
----------------

A simple Ruby script to back up MySQL databases, MongoDB databases, full directories, and groups of single files to any FTP host.
It's a "handsoff" script, the most is done for you.

**Features**

* Database backup (MySQL, MongoDB)
* Directory backup
* Subdirectories backup
* File backup
* Split files
* Set compression rate
* FTP error catching
* Days of archive cleanup
* Backups ordered in buckets and daily folders
* Archives symlinks as file or the target files

**Steps for using:**

1. Set up your FTP server
2. Get the script: git clone https://github.com/cubetech/simple-ftp-backup.git
3. Install the gems via Bundler, or install the gems listed in Gemfile manually.
4. Rename settings.rb.sample to settings.rb
5. In settings.rb, fill in specific command paths, FTP credentials, MySQL login info & databases, and any directories you want backed up.  Just comment out the constants for backups you don't want to run.
6. Set the script to run with cron - I have mine run every night, like so:

`15 3 * * * /usr/local/simple-ftp-backup/simple-ftp-backup.rb`

**To do:**

1. Improvements with the file structure
