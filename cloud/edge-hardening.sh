#!/bin/bash
#
# Intended for Ubuntu 18 64bit base image on SL
#

LOG=/root/postinstall.out
exec > >(tee -a ${LOG} )
exec 2> >(tee -a ${LOG} >&2)

set -x

# keep lots of system logs
apt-get update
apt-get install -y jq

#### Workaround for ssh-keys authorize_keys while -k doesn't work with cloud CLI
mkdir -m 700 /root/.ssh
curl https://api.service.softlayer.com/rest/v3/SoftLayer_Resource_Metadata/getUserMetadata.json 2>/dev/null | tr -d \'\\ 2>/dev/null | tail -c +2 | head -c -1 | jq -M -r '.["cg-key"], .["my-key"]' | sort -u > /root/.ssh/authorized_keys

#### On the fence about purging this, or enabling it and adding auto kernel cleanup ... Purge is better for stable
#### dev environments, enabled is obviously better for security, since this is a hardening script, let's keep it
#apt-get purge -y ufw unattended-upgrades
#rm -Rf /var/log/unattended-upgrades/
sed -i 's/^\/\/Unattended-Upgrade.*/Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";/' /etc/apt/apt.conf.d/50unattended-upgrades
systemctl restart unattended-upgrades

export DEBIAN_FRONTEND=noninteractive
#apt-get install -y cron-apt aptitude iftop tree auditd bsd-mailx ssmtp jq logwatch ntp
apt-get install -y cron-apt
apt-get install -y aptitude
apt-get install -y iftop
apt-get install -y tree
apt-get install -y auditd
apt-get install -y bsd-mailx
apt-get install -y ssmtp
apt-get install -y logwatch
apt-get install -y ntp

# configure ssh access
usermod -aG ssh root
sed -i 's/^PermitRootLogin.*/PermitRootLogin without-password/' /etc/ssh/sshd_config
printf "\nAllowGroups ssh" >> /etc/ssh/sshd_config
systemctl restart sshd

#### This only protects the host to the extent no one messes with iptables, 
#### docker default port mappings override this (-p 80:80 will get through ... don't use that!)
# configure iptables
cat <<'EOF' > /etc/network/if-pre-up.d/iptables
#!/bin/sh
iptables-restore < /etc/iptables.rules
exit 0
EOF

chmod +x /etc/network/if-pre-up.d/iptables

# write iptables default rules
cat <<'EOF' > /etc/iptables.rules
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i eth1 -p tcp -m tcp --dport 22 -j ACCEPT
-A INPUT -i eth1 -j DROP
COMMIT
EOF

/etc/network/if-pre-up.d/iptables

sed -i 's/rotate.*/rotate 20/' /etc/logrotate.d/rsyslog

echo "update -o quiet=2" > /etc/cron-apt/action.d/0-update
cat <<'EOF' > /etc/cron-apt/action.d/5-security
autoclean -q -y
dist-upgrade -q -y -o APT::Get::Show-Upgraded=true \
                   -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/security.sources.list \
                   -o DPkg::Options::=--force-confdef \
                   -o DPkg::Options::=--force-confold
EOF

cat /etc/apt/sources.list | grep xenial-security > /etc/apt/sources.list.d/security.sources.list
sed -i '/security/d' /etc/apt/sources.list

#### Get this working with our infrastructure
# configure mail (for alerts)
#echo "root:sysreport@edge-fabric.com" > /etc/ssmtp/revaliases
#echo "alias root sysreport@edge-fabric.com" > /etc/mail.rc
#cat <<EOF > /etc/ssmtp/ssmtp.conf
#root=sysreport@edge-fabric.com
#mailhub=edge-fabric.com
#rewriteDomain=edge-fabric.com
#UseSTARTTLS=YES
#hostname=$(hostname -f)
#EOF

systemctl enable ntp && systemctl start ntp

# configure auditd
cp /etc/audit/rules.d/audit.rules /etc/audit/rules.d/audit.rules.orig
cat <<'EOF' > /etc/audit/rules.d/audit.rules
-D
-b 8192
-f 1
--loginuid-immutable
-a always,exit -F arch=b64 -S adjtimex,settimeofday -F key=time-change
-a always,exit -F arch=b64 -S clock_settime -F a0=0x0 -F key=time-change
-w /etc/localtime -p wa -k time-change
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-a always,exit -F arch=b64 -S sethostname,setdomainname -F key=system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/sysconfig/network -p wa -k system-locale
-a always,exit -F dir=/etc/NetworkManager/ -F perm=wa -F key=system-locale
-a always,exit -F dir=/etc/selinux/ -F perm=wa -F key=MAC-policy
-w /var/log/tallylog -p wa -k logins
-w /var/run/faillock/ -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-a always,exit -F arch=b64 -S open,truncate,ftruncate,creat,openat,open_by_handle_at -F exit=-EACCES -F auid>=500 -F auid!=4294967295 -F key=access
-a always,exit -F arch=b64 -S open,truncate,ftruncate,creat,openat,open_by_handle_at -F exit=-EPERM -F auid>=500 -F auid!=4294967295 -F key=access
-e 2
EOF
systemctl enable auditd && systemctl start auditd

# install and configure docker with syslog forwarding
curl https://get.docker.com/ | sh
sed -i 's/.*DOCKER_OPTS=.*/DOCKER_OPTS="--log-driver=syslog"/' /etc/default/docker
DOCKER_SERVICE_FILE='/lib/systemd/system/docker.service'
grep -q 'DOCKER_OPTS$' $DOCKER_SERVICE_FILE || sed -i '/^ExecStart=/ s/$/ $DOCKER_OPTS/' $DOCKER_SERVICE_FILE
sed -i '/^EnvironmentFile=/d' $DOCKER_SERVICE_FILE
sed -i 's/^ExecReload=/EnvironmentFile=\/etc\/default\/docker\nExecReload=/' $DOCKER_SERVICE_FILE

cat <<'EOF' > /etc/rsyslog.d/22-docker.conf
$template DynamicContainerFile,"/var/log/%syslogtag:R,ERE,1,DFLT:.*docker/([^\[]+)--end%.log"

:syslogtag, startswith, "docker/" -?DynamicContainerFile
& stop
:syslogtag, startswith, "docker" -/var/log/docker.log
& stop
EOF

systemctl enable docker && systemctl restart docker
systemctl restart rsyslog.service
