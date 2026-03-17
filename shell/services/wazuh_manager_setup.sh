#!/bin/bash
if [ "$(id -u || true)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

curl -sO https://packages.wazuh.com/4.14/wazuh-install.sh

curl -sO https://packages.wazuh.com/4.14/config.yml

sed -i "s/ip:.*/ip: 127.0.0.1/g" config.yml

./wazuh_server_setup.sh --generate-config-files
./wazuh_server_setup.sh -a -i -o

curl -so ~/wazuh_socfortress_rules.sh https://raw.githubusercontent.com/socfortress/Wazuh-Rules/main/wazuh_socfortress_rules.sh && bash ~/wazuh_socfortress_rules.sh
