#!/bin/bash
#
# Intended for Ubuntu 18 64bit base image on SL
#

LOG=/root/postinstall.out
exec > >(tee -a ${LOG} )
exec 2> >(tee -a ${LOG} >&2)

set -x

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y jq iftop tree bsd-mailx ssmtp jq logwatch ntp

#### On the fence about purging this, or enabling it and adding auto kernel cleanup ... Purge is better for stable
#### dev environments, enabled is obviously better for security, since this is a hardening script, let's keep it
#apt-get purge -y ufw unattended-upgrades
#rm -Rf /var/log/unattended-upgrades/
sed -i 's/^\/\/Unattended-Upgrade.*/Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";/' /etc/apt/apt.conf.d/50unattended-upgrades
systemctl restart unattended-upgrades


#### Workaround for ssh-keys authorize_keys while -k doesn't work with cloud CLI
mkdir -m 700 /root/.ssh
curl https://api.service.softlayer.com/rest/v3/SoftLayer_Resource_Metadata/getUserMetadata.json 2>/dev/null | tr -d \'\\ 2>/dev/null | tail -c +2 | head -c -1 | jq -M -r '.["cg-key"], .["my-key"]' | sort -u > /root/.ssh/authorized_keys

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

# install docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get install -y docker-ce

# Keep more syslogs
sed -i 's/rotate.*/rotate 20/' /etc/logrotate.d/rsyslog
systemctl restart rsyslog.service

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

apt-get install -y ntp
systemctl enable ntp && systemctl start ntp

apt-get install -y auditd

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
