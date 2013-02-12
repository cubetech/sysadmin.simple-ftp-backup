Simple FTP Backup
----------------

A simple Ruby script to back up MySQL databases, MongoDB databases, full directories, and groups of single files to any FTP host.

**Steps for using:**

1. Set up your FTP server
2. Install the gems via Bundler, or install the gems listed in Gemfile manually.
3. Rename settings-sample.rb to settings.rb
4. In settings.rb, fill in specific command paths, FTP credentials, MySQL login info & databases, and any directories you want backed up.  Just comment out the constants for backups you don't want to run.
5. Set the script to run with cron - I have mine run every night, like so:

`15 3 * * * /usr/bin/ruby /home/username/backups/simple-ftp-backup.rb`

**To do:**

1. Split daily archives into separate directories in the FTP server? Would be helpful for those with lots of files, and lots of days
