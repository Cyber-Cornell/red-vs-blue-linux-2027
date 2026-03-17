#!/bin/sh

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

# Thanks gemini
if [ -d /run/systemd/system ]; then
    INIT_SYS="systemd"
elif [ -x /sbin/openrc-run ] || [ -x /sbin/rc-service ]; then
    INIT_SYS="openrc"
else
    INIT_SYS="unknown"
fi

for service in apache2 httpd apache; do
    if [ "$INIT_SYS" = "systemd" ] && systemctl list-unit-files | grep -q "^$service.service"; then
        APACHE_NAME=$service
        break
    elif [ "$INIT_SYS" = "openrc" ] && [ -f "/etc/init.d/$service" ]; then
        APACHE_NAME=$service
        break
    fi
done

if [ -z "$APACHE_NAME" ]; then
    echo "Error: Apache service not found."
    exit 1
fi

if [ "$APACHE_NAME" = "apache2" ]; then
    MAIN_CONFIG="/etc/apache2/apache2.conf"
else
    # For 'httpd', the config is often in a /conf/ subfolder
    MAIN_CONFIG="/etc/httpd/conf/httpd.conf"
fi

# Unblock http(s)
iptables -I INPUT -p tcp --dport 80 -j ACCEPT
iptables -I INPUT -p tcp --dport 443 -j ACCEPT
iptables -I OUTPUT -p tcp --sport 443 -j ACCEPT
iptables -I OUTPUT -p tcp --sport 80 -j ACCEPT

# Run apache as non root user
groupadd -r www-data
useradd www-data -r -g www-data -d /var/www -s /sbin/nologin
usermod -g www-data -d /var/www -s /sbin/nologin www-data
if [ "$(id -u www-data)" -eq 0 ]; then
    printf "\033[0;31mwww-data is root!\033[0m"
fi

if [ "$APACHE_NAME" = "apache2" ]; then
    sed -i '/APACHE_RUN_USER/cexport APACHE_RUN_USER=www-data' /etc/"${APACHE_NAME}"/envvars
    sed -i '/APACHE_RUN_GROUP/cexport APACHE_RUN_GROUP=www-data' /etc/"${APACHE_NAME}"/envvars
else
    sed -i '/User apache/cUser www-data' ${MAIN_CONFIG}
    sed -i '/Group apache/cGroup www-data' ${MAIN_CONFIG}
fi

# Lock the apache user acccount
passwd -l www-data > /dev/null

# Change apache file ownership to root
chown -R root:root /etc/"${APACHE_NAME}"
chown -R root:root /var/www/html

# Remove write access to apache files
chmod -R o-w /etc/"${APACHE_NAME}"
chmod -R g-w /etc/"${APACHE_NAME}"

# Disable core dumps
sed -i '/CoreDumpDirectory/c#CoreDumpDirectory' ${MAIN_CONFIG}

# Fix perms on config file
chmod 600 ${MAIN_CONFIG}

if [ "$APACHE_NAME" = "apache2" ]; then
    # ServerTokens to Prod
    sed -i '/^ServerTokens/cServerTokens Prod' /etc/"${APACHE_NAME}"/conf-available/security.conf
    
    # ServerSignature Off
    sed -i '/^ServerSignature/cServerSignature Off' /etc/"${APACHE_NAME}"/conf-available/security.conf
    
    # Disable .htaccess overrides
    sed -i 's/AllowOverride All/AllowOverride None/g' ${MAIN_CONFIG}
    sed -i 's/AllowOverride .*/AllowOverride None/g' ${MAIN_CONFIG}
    
    # Disable HTTP TRACE
    sed -i '/TraceEnable/cTraceEnable Off' /etc/"${APACHE_NAME}"/conf-available/security.conf

    # List apache modules
    ls -al /etc/"${APACHE_NAME}"/mods-enabled
    
    # Disable WebDAV, status, autoindex, UserDir, info
    # I read some stuff about disabling CGI, not sure if it's safe to do in a script
    a2dismod dav dav_fs dav_lock status autoindex userdir info
else
    # ServerTokens to Prod
    echo "ServerTokens Prod" >> ${MAIN_CONFIG}
    sed -i '/^ServerTokens/cServerTokens Prod' ${MAIN_CONFIG}
    
    # ServerSignature Off
    echo "ServerSignature Off" >> ${MAIN_CONFIG}
    sed -i '/^ServerSignature/cServerSignature Off' ${MAIN_CONFIG}
    
    # Disable .htaccess overrides
    sed -i 's/AllowOverride All/AllowOverride None/g' ${MAIN_CONFIG}
    sed -i 's/AllowOverride .*/AllowOverride None/g' ${MAIN_CONFIG}
    
    # Disable HTTP TRACE
    echo "TraceEnable Off" >> ${MAIN_CONFIG}
    sed -i '/TraceEnable/cTraceEnable Off' ${MAIN_CONFIG}

    # List apache modules
    ls -al /etc/httpd/modules
fi

# Install Modsecurity

if command -v apt > /dev/null 2>&1; then
    apt-get install libapache2-mod-security2 -y
elif command -v dnf > /dev/null 2>&1; then
    dnf install mod_security -y
elif command -v yum > /dev/null 2>&1; then
    yum install mod_security -y
else
    echo "No recognized package manager found."
    exit 1
fi

if [ "$APACHE_NAME" = "apache2" ]; then
    a2enmod headers
    # Rename the config file
    mv /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf
    sed -i '/SecRuleEngine/cSecRuleEngine On' /etc/modsecurity/modsecurity.conf
fi

case "$INIT_SYS" in
    systemd)
        sudo systemctl restart "$APACHE_NAME"
        ;;
    openrc)
        sudo rc-service "$APACHE_NAME" restart
        ;;
    *)
        echo "Unsupported init system."
        exit 1
        ;;
esac

case "$INIT_SYS" in
    systemd)
        sudo systemctl restart "$APACHE_NAME"
        ;;
    openrc)
        sudo rc-service "$APACHE_NAME" restart
        ;;
    *)
        echo "Unsupported init system."
        exit 1
        ;;
esac
