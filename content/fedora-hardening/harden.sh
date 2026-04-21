#!/usr/bin/env bash
# Fedora 43 System Hardening Script
# Run as root: sudo bash fedora43_hardening.sh

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo -e "\n${CYAN}========== $* ==========${NC}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root: sudo bash $0${NC}"; exit 1; }

LOG="/var/log/fedora_hardening_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
info "Logging to $LOG"


section "System Update"
dnf upgrade -y --refresh
ok "System updated"


section "Installing Security Tools"
dnf install -y \
    aide \
    audit \
    auditd \
    fail2ban \
    firewalld \
    libpwquality \
    policycoreutils-python-utils \
    rsyslog \
    selinux-policy-targeted \
    setroubleshoot-server \
    usbguard \
    rkhunter \
    chrony
ok "Security tools installed"


section "SELinux"
if sestatus | grep -q "disabled"; then
    sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
    warn "SELinux was disabled — set to enforcing. Reboot required."
elif sestatus | grep -q "permissive"; then
    setenforce 1
    sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
    ok "SELinux set to enforcing"
else
    ok "SELinux already enforcing"
fi


section "Firewall"
systemctl enable --now firewalld
firewall-cmd --set-default-zone=public --permanent
firewall-cmd --zone=public --set-target=DROP --permanent
firewall-cmd --zone=public --add-service=ssh --permanent
firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" log prefix="FIREWALL-DROP " level="warning" limit value="5/m" drop' --permanent
firewall-cmd --reload
ok "Firewall configured"


section "SSH Hardening"
SSHD=/etc/ssh/sshd_config
cp "$SSHD" "${SSHD}.bak.$(date +%Y%m%d)"

set_ssh() {
    local key=$1 val=$2
    if grep -qE "^#?${key}" "$SSHD"; then
        sed -i "s/^#\?${key}.*/${key} ${val}/" "$SSHD"
    else
        echo "${key} ${val}" >> "$SSHD"
    fi
}

set_ssh PermitRootLogin           no
set_ssh PasswordAuthentication    no
set_ssh PermitEmptyPasswords      no
set_ssh PubkeyAuthentication      yes
set_ssh AuthorizedKeysFile        ".ssh/authorized_keys"
set_ssh X11Forwarding             no
set_ssh AllowTcpForwarding        no
set_ssh UsePAM                    yes
set_ssh MaxAuthTries              3
set_ssh MaxSessions               5
set_ssh LoginGraceTime            30
set_ssh ClientAliveInterval       300
set_ssh ClientAliveCountMax       2
set_ssh IgnoreRhosts              yes
set_ssh HostbasedAuthentication   no
set_ssh Banner                    /etc/issue.net
set_ssh LogLevel                  VERBOSE

cat > /etc/issue.net << 'EOF'
***************************************************************************
                         AUTHORIZED ACCESS ONLY
  Unauthorized access to this system is prohibited and will be prosecuted.
***************************************************************************
EOF

sshd -t && systemctl restart sshd
ok "SSH hardened"


section "Password Policy"
cat > /etc/security/pwquality.conf << 'EOF'
minlen = 14
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
minclass = 4
maxrepeat = 3
maxsequence = 3
gecoscheck = 1
dictcheck = 1
EOF

cat > /etc/security/faillock.conf << 'EOF'
deny = 5
unlock_time = 900
fail_interval = 900
silent
audit
EOF

sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/'  /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   7/'   /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/'  /etc/login.defs
ok "Password policy configured"


section "Kernel Hardening"
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 3
kernel.yama.ptrace_scope = 1
kernel.sysrq = 0
kernel.unprivileged_bpf_disabled = 1
kernel.core_uses_pid = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF

sysctl --system
ok "Kernel parameters applied"


section "Kernel Module Blacklist"
cat > /etc/modprobe.d/hardening-blacklist.conf << 'EOF'
install dccp      /bin/false
install sctp      /bin/false
install rds       /bin/false
install tipc      /bin/false
install n-hdlc    /bin/false
install ax25      /bin/false
install netrom    /bin/false
install x25       /bin/false
install rose      /bin/false
install decnet    /bin/false
install econet    /bin/false
install af_802154 /bin/false
install ipx       /bin/false
install appletalk /bin/false
install psnap     /bin/false
install p8022     /bin/false
install p8023     /bin/false
install cramfs    /bin/false
install freevxfs  /bin/false
install jffs2     /bin/false
install hfs       /bin/false
install hfsplus   /bin/false
install udf       /bin/false
EOF
ok "Kernel module blacklist written"


section "Audit Rules"
cat > /etc/audit/rules.d/99-hardening.rules << 'EOF'
-D
-b 8192
-f 1
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change
-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S stime -k time-change
-w /etc/localtime -p wa -k time-change
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/sysconfig/network -p wa -k system-locale
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock -p wa -k logins
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-a always,exit -F path=/usr/bin/passwd  -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/sudo    -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/su      -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/useradd -F perm=x -F auid>=1000 -k privileged
-a always,exit -F path=/usr/sbin/userdel -F perm=x -F auid>=1000 -k privileged
-a always,exit -F path=/usr/sbin/usermod -F perm=x -F auid>=1000 -k privileged
-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EPERM  -F auid>=1000 -F auid!=4294967295 -k access
-w /sbin/insmod   -p x -k modules
-w /sbin/rmmod    -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module -S delete_module -k modules
-e 2
EOF

systemctl restart auditd
ok "Auditd configured"


section "Fail2ban"
cat > /etc/fail2ban/jail.d/hardening.conf << 'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 86400
EOF

systemctl enable --now fail2ban
ok "Fail2ban enabled"


section "USBGuard"
if ! systemctl is-active --quiet usbguard; then
    usbguard generate-policy > /etc/usbguard/rules.conf 2>/dev/null || true
    systemctl enable --now usbguard
    ok "USBGuard enabled"
else
    ok "USBGuard already running"
fi


section "Time Sync"
systemctl enable --now chronyd
ok "chrony enabled"


section "AIDE"
if [[ ! -f /var/lib/aide/aide.db.gz ]]; then
    info "Building AIDE database..."
    aide --init && mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
    ok "AIDE database created"
else
    ok "AIDE database already exists"
fi

cat > /etc/cron.weekly/aide-check << 'EOF'
#!/bin/bash
/usr/sbin/aide --check 2>&1 | mail -s "AIDE Report $(hostname)" root
EOF
chmod +x /etc/cron.weekly/aide-check
ok "AIDE weekly cron installed"


section "File Permissions"
chmod 600 /etc/shadow
chmod 600 /etc/gshadow
chmod 644 /etc/passwd
chmod 644 /etc/group
chmod 700 /root
chmod 600 /boot/grub2/grub.cfg 2>/dev/null || true
ok "File permissions set"


section "Disable Unnecessary Services"
SERVICES=(avahi-daemon bluetooth cups rpcbind nfs-server vsftpd telnet rsh ypbind)
for svc in "${SERVICES[@]}"; do
    systemctl disable --now "$svc" 2>/dev/null && info "Disabled: $svc" || true
done
ok "Unnecessary services disabled"


section "umask"
for f in /etc/profile /etc/bashrc; do
    grep -q "umask 027" "$f" || echo "umask 027" >> "$f"
done
ok "umask 027 set"


section "Core Dumps"
grep -q "* hard core 0" /etc/security/limits.conf || {
    echo "* hard core 0" >> /etc/security/limits.conf
    echo "* soft core 0" >> /etc/security/limits.conf
}
echo "fs.suid_dumpable = 0" > /etc/sysctl.d/99-nodumps.conf
sysctl -p /etc/sysctl.d/99-nodumps.conf
ok "Core dumps disabled"


section "rkhunter"
rkhunter --update --nocolors 2>/dev/null || true
rkhunter --propupd --nocolors 2>/dev/null || true
cat > /etc/cron.weekly/rkhunter << 'EOF'
#!/bin/bash
/usr/bin/rkhunter --check --nocolors --skip-keypress 2>&1 | mail -s "rkhunter Report $(hostname)" root
EOF
chmod +x /etc/cron.weekly/rkhunter
ok "rkhunter configured"


section "Hardening Complete"
echo -e "${GREEN}"
cat << 'EOF'
  ✔  System updated
  ✔  Security tools installed
  ✔  SELinux enforcing
  ✔  Firewall configured
  ✔  SSH hardened
  ✔  Password / lockout policy applied
  ✔  Kernel sysctl hardened
  ✔  Kernel modules blacklisted
  ✔  Auditd rules applied
  ✔  Fail2ban enabled
  ✔  USBGuard enabled
  ✔  Time sync enabled
  ✔  AIDE initialised
  ✔  File permissions set
  ✔  Unnecessary services disabled
  ✔  umask 027 applied
  ✔  Core dumps disabled
  ✔  rkhunter configured

  !! Reboot to activate all kernel/SELinux changes !!
EOF
echo -e "${NC}"
info "Full log: $LOG"
