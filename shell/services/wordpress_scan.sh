#!/bin/sh

if [ "$(id -u)" -eq 0 ]; then
  echo "DONT run as root"
  exit 1
fi

# Download and install WP-CLI
if command -v apt > /dev/null 2>&1; then
    sudo apt install curl -y
elif command -v dnf > /dev/null 2>&1; then
    sudo dnf install curl -y
elif command -v yum > /dev/null 2>&1; then
    sudo yum install curl -y
else
    echo "No recognized package manager found."
    exit 1
fi

sudo curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
sudo chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp


# Download and use WP vulnerability scanner
wp package install 10up/wpcli-vulnerability-scanner:dev-stable
sudo echo  "define( 'VULN_API_PROVIDER', 'wordfence');" >> /var/www/html/wp-config.php
echo "manually use 'wp core/plugin verify-checksums' and 'wp user list' in the wordpress directory"
echo "manually use 'wp vuln status' in the wordpress directory"
