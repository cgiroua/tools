#!/bin/bash

# Logging
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>/root/postinstall.out 2>&1
set -x


# Setup docker repo
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

# Apt installs
export DEBIAN_FRONTEND=noninteractive
echo "Start update"
apt-get update

echo "Start install"
apt-get install -y jq iftop tree bsd-mailx ssmtp jq logwatch ntp docker-ce auditd
echo "Finish install, won't see this"
