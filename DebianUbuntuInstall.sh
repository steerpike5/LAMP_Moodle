#!/bin/bash

# Prompt for the web address
read -p "Enter the web address: " WEBSITE_ADDRESS

# Check if the input is not empty
if [ -n "$WEBSITE_ADDRESS" ]; then
    # Validate the input as a valid FQDN or IPv4 address
    if [[ $WEBSITE_ADDRESS =~ ^((http|https):\/\/)?[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(\/\S*)?$ ]]; then
        # If the input is a valid FQDN, set FQDN to the entered value
        FQDN="y"
    elif [[ $WEBSITE_ADDRESS =~ ^((http|https):\/\/)?([0-9]{1,3}\.){3}[0-9]{1,3}(\/\S*)?$ ]]; then
        FQDN="n"
    else
        echo "Invalid web address. Please enter a valid FQDN or IPv4 address (e.g., http://example.com or http://192.168.1.100)."
        exit 1
    fi
fi


#Step 1 Update the system and install git, Apache, PHP and modules required by Moodle
sudo apt-get update
sudo apt upgrade -y
sudo apt-get install -y apache2 php libapache2-mod-php php-mysql graphviz aspell git 
sudo apt-get install -y clamav php-pspell php-curl php-gd php-intl php-mysql ghostscript
sudo apt-get install -y php-xml php-xmlrpc php-ldap php-zip php-soap php-mbstring
sudo apt-get install -y  ufw unzip
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
#Install Debian default database MariaDB 
sudo apt-get install -y mariadb-server mariadb-client
echo "Step 1 has completed."


# Step 2 Set up the firewall
sudo ufw --force enable
# Set default policies to deny incoming and allow outgoing traffic
sudo ufw default deny incoming
sudo ufw default allow outgoing
# Allow SSH (port 22) for remote access
# Allow HTTP (port 80) and HTTPS (port 443) for web server 
# Allow MySQL (port 3306) for database access
sudo ufw allow ssh
sudo ufw allow 80
sudo ufw allow 443
sudo ufw allow 3306
sudo ufw reload
echo "Step 2 has completed."


#Step 3 Set up daily security updates
# Configure unattended-upgrades
sudo tee /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}:\${distro_codename}-updates";
};
EOF
# Enable automatic updates
sudo tee /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
# Restart the unattended-upgrades service
sudo systemctl restart unattended-upgrades
echo "Step 3 has completed."

# Step 4 Clone the Moodle repository into /var/www
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
# Set MoodleVersion based on PHP version
if [ "$php_version" = "7.4" ]; then
    MoodleVersion="MOODLE_401_STABLE"
elif [ "$(php -r "echo version_compare('$php_version', '8.1');")" -ge 0 ]; then
    MoodleVersion="MOODLE_402_STABLE"
else
    echo "Unsupported PHP version: $php_version"
    exit 1
fi
echo "Installing $MoodleVersion based on your php version $php_version"
echo "Cloning Moodle repository into /opt and copying to /var/www/"
echo "Be patient, this can take several minutes."
cd /var/www
sudo git clone https://github.com/moodle/moodle.git
cd moodle
sudo git checkout -t origin/$MoodleVersion
git config pull.ff only
ORIG_COMMIT=$(git rev-parse HEAD)
LAST_COMMIT=$ORIG_COMMIT
echo "Step 4 has completed."

# Step 5a  Create a user to run backups
# Generate a random password for backupuser
backupuserPW=$(openssl rand -base64 12)
sudo useradd -m -d "/home/backupuser" -s "/bin/bash" "backupuser"
echo "backupuser:$backupuserPW" | sudo chpasswd
sudo usermod -aG mysql "backupuser"
# Create and set permissions for .my.cnf
backupuser_home="/home/backupuser"
mycnf_file="$backupuser_home/.my.cnf"
# Create .my.cnf file with correct permissions
echo "[mysqldump]" | sudo tee "$mycnf_file" > /dev/null
echo "user=backupuser" | sudo tee -a "$mycnf_file" > /dev/null
echo "password=$backupuserPW" | sudo tee -a "$mycnf_file" > /dev/null
sudo chmod 600 "$mycnf_file"
sudo chown backupuser:backupuser "$mycnf_file"
# Securely erase the password from memory


# Step 5  Create a Moodle Virtual Host File and call certbot for https encryption
# Strip the 'http://' or 'https://' part from the web address
FQDN_ADDRESS=$(echo "$WEBSITE_ADDRESS" | sed -e 's#^https\?://##')
# Create a new moodle.conf file
cat << EOF | sudo tee /etc/apache2/sites-available/moodle.conf
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/moodle
    ServerName "$FQDN_ADDRESS"
    ServerAlias "www.$FQDN_ADDRESS"

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
sudo a2dissite 000-default.conf
sudo a2ensite moodle.conf
if [ "$FQDN" = "y" ]; then
    if [ ! -d "/etc/letsencrypt" ]; then
        echo "Setting up SSL Certificates for your website"
        sudo apt install certbot python3-certbot-apache
        sudo ufw allow 'Apache Full'
        sudo ufw delete allow 'Apache'
        sudo certbot --apache
        WEBSITE_ADDRESS="https://${FQDN_ADDRESS#http://}"
    fi
fi
systemctl reload apache2
echo "Step 5 has completed."


# Step 6 Directories, ownership, permissions and php.ini required by 
sudo mkdir -p /var/www/moodledata
sudo chown -R www-data /var/www/moodledata
sudo chmod -R 777 /var/www/moodledata
sudo chmod -R 755 /var/www/moodle
# Update the php.ini files, required to pass Moodle install check
sudo sed -i 's/.*max_input_vars =.*/max_input_vars = 5000/' /etc/php/$PHP_VERSION/apache2/php.ini
sudo sed -i 's/.*max_input_vars =.*/max_input_vars = 5000/' /etc/php/$PHP_VERSION/cli/php.ini
sudo sed -i 's/.*post_max_size =.*/post_max_size = 80M/' /etc/php/$PHP_VERSION/apache2/php.ini
sudo sed -i 's/.*upload_max_filesize =.*/upload_max_filesize = 80M/' /etc/php/$PHP_VERSION/apache2/php.ini
# Restart Apache to allow changes to take place
sudo service apache2 restart
# Install adminer, phpmyadmin alternative
cd /var/www/moodle/local 
sudo wget https://moodle.org/plugins/download.php/28045/local_adminer_moodle42_2021051702.zip
sudo unzip local_adminer_moodle42_2021051702.zip
sudo rm local_adminer_moodle42_2021051702.zip 
echo "Step 6 has completed."

# Step 7 Set up cron job to run every minute 
echo "Cron job added for the www-data user."
CRON_JOB="* * * * * /var/www/moodle/admin/cli/cron.php >/dev/null"
echo "$CRON_JOB" > /tmp/moodle_cron
sudo crontab -u www-data /tmp/moodle_cron
sudo rm /tmp/moodle_cron
echo "Step 7 has completed."

# Step 8 Set up a cron job to keep 401 up to date
# Set the URL of the update script in your repository
UPDATE_SCRIPT_URL="https://github.com/steerpike5/LAMP_Moodle/raw/FQDN/moodle_update.sh"
# Directory where the update script will be placed
OPT_DIR="/opt"
# Download the update script and place it in the /opt directory
wget -O "$OPT_DIR/moodle_upgrade.sh" "$UPDATE_SCRIPT_URL"
# Add execute permissions to the update script
chmod +x "$OPT_DIR/moodle_upgrade.sh"
# Add a cron job to run the update script nightly
CRON_JOB="0 0 * * * $OPT_DIR/moodle_upgrade.sh"
# Add the cron job to the user's crontab
(crontab -l ; echo "$CRON_JOB") | crontab 
# Step 8 Finished


#  Step 9 Generate a random password for backupuser
backupuserPW=$(openssl rand -base64 12)
# Create backupuser
sudo useradd -m -d "/home/backupuser" -s "/bin/bash" "backupuser"
# Set password for backupuser
echo "backupuser:$backupuserPW" | sudo chpasswd
# Add backupuser to the mysql group
sudo usermod -aG mysql "backupuser"
# Create and set permissions for .my.cnf
backupuser_home="/home/backupuser"
mycnf_file="$backupuser_home/.my.cnf"
# Create .my.cnf file with correct permissions
echo "[mysqldump]" | sudo tee "$mycnf_file" > /dev/null
echo "user=backupuser" | sudo tee -a "$mycnf_file" > /dev/null
echo "password=$backupuserPW" | sudo tee -a "$mycnf_file" > /dev/null
sudo chmod 600 "$mycnf_file"
sudo chown backupuser:backupuser "$mycnf_file"
# Securely erase the password from memory
unset backupuserPW
# Step9 Finished




# Step 8 Secure the MySQL service and create the database and user for Moodle
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 6)
MYSQL_MOODLEUSER_PASSWORD=$(openssl rand -base64 6)
MOODLE_ADMIN_PASSWORD=$(openssl rand -base64 6)
# Set the root password using mysqladmin
sudo mysqladmin -u root password "$MYSQL_ROOT_PASSWORD"
# Create the Moodle database and user
echo "Creating the Moodle database and user..."
mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE DATABASE moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'moodleuser'@'localhost' IDENTIFIED BY '$MYSQL_MOODLEUSER_PASSWORD';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, CREATE TEMPORARY TABLES, DROP, INDEX, ALTER ON moodle.* TO 'moodleuser'@'localhost';
\q
EOF
sudo chmod -R 777 /var/www/moodle
sudo mkdir /etc/moodle_installation
sudo chmod 700 /etc/moodle_installation
# Create info.txt and add installation details with date and time
sudo bash -c "echo 'Installation script' > /etc/moodle_installation/info.txt"
sudo bash -c "echo 'Date and Time of Installation: $(date)' >> /etc/moodle_installation/info.txt"
sudo bash -c "echo 'Web Address: $WEBSITE_ADDRESS ' >> /etc/moodle_installation/info.txt"
sudo bash -c "echo 'Moodle SQL user password: $MYSQL_MOODLEUSER_PASSWORD' >> /etc/moodle_installation/info.txt"
sudo bash -c "echo 'Moodle root user password: $MYSQL_ROOT_PASSWORD' >> /etc/moodle_installation/info.txt"
sudo bash -c "echo 'The following password is used by admin to log on to Moodle' >> /etc/moodle_installation/info.txt"
sudo bash -c "echo 'Moodle Site Password for admin: $MOODLE_ADMIN_PASSWORD' >> /etc/moodle_installation/info.txt"
cat /etc/moodle_installation/info.txt


echo "Step 8 has completed."

#Step 9 Finish the install 
echo "The script will now try to finish the installation. If this fails, log on to your site at $WEBSITE_ADDRESS and follow the prompts."
INSTALL_COMMAND="sudo -u www-data /usr/bin/php /var/www/moodle/admin/cli/install.php \
    --non-interactive \
    --lang=en \
    --wwwroot=\"$WEBSITE_ADDRESS\" \
    --dataroot=/var/www/moodledata \
    --dbtype=mariadb \
    --dbhost=localhost \
    --dbname=moodle \
    --dbuser=moodleuser \
    --dbpass=\"$MYSQL_MOODLEUSER_PASSWORD\" \
    --fullname=Dummy_Name\
    --shortname=\DN \
    --adminuser=admin \
    --summary=\"\" \
    --adminpass=\"$MOODLE_ADMIN_PASSWORD\" \
    --adminemail=joe@123.com \
    --agree-license"

if eval "$INSTALL_COMMAND"; then
    echo "Moodle installation completed successfully."
    chmod -R 755 /var/www/moodle
    echo "You can now log on to your new Moodle at $WEBSITE_ADDRESS as admin with $MOODLE_ADMIN_PASSWORD"
else
    echo "Error: Moodle installation encountered an error. Go to $WEBSITE_ADDRESS and follow the prompts to complete the installation."

fi
# Display the generated passwords (if needed, for reference)
sudo cat /etc/moodle_installation/info.txt
#Step 9 has finished"












