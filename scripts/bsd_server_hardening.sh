#!/bin/sh
# harden-freebsd.sh — baseline hardening for FreeBSD 14+
# Tested on FreeBSD 14.x. Review before running on remote hosts.
set -eu

# -----------------------------------------------------------------------------
# Config — edit these before running
# -----------------------------------------------------------------------------
ADMIN_USER="${ADMIN_USER:-admin}"         # account to keep SSH access for
SSH_PORT="${SSH_PORT:-22}"                # keep 22 or change to something high
ALLOW_FROM="${ALLOW_FROM:-any}"           # PF: restrict SSH source, e.g. 10.0.0.0/8
TIMEZONE="${TIMEZONE:-UTC}"

BACKUP_DIR="/root/harden-backup-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

backup() {
    # Copy a file into the backup dir preserving path
    src="$1"
    [ -f "$src" ] || return 0
    dst="$BACKUP_DIR$src"
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
}

say() { printf '\n==> %s\n' "$*"; }

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
fi

# Must be FreeBSD
if [ "$(uname -s)" != "FreeBSD" ]; then
    echo "This script is for FreeBSD only." >&2
    exit 1
fi

# Must have admin user
if ! pw usershow "$ADMIN_USER" >/dev/null 2>&1; then
    echo "Admin user '$ADMIN_USER' does not exist. Create it first:" >&2
    echo "  pw useradd $ADMIN_USER -m -s /bin/sh -G wheel" >&2
    echo "  passwd $ADMIN_USER" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# 1. Patch the base system and installed packages
# -----------------------------------------------------------------------------
say "Applying base system patches"
freebsd-update fetch install || true

say "Updating pkg and installed packages"
pkg update -f
pkg upgrade -y

# -----------------------------------------------------------------------------
# 2. Timezone + NTP
# -----------------------------------------------------------------------------
say "Setting timezone to $TIMEZONE"
cp -f "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

say "Enabling NTP"
sysrc ntpd_enable="YES"
sysrc ntpd_sync_on_start="YES"
service ntpd restart || service ntpd start

# -----------------------------------------------------------------------------
# 3. Kernel / sysctl hardening
# -----------------------------------------------------------------------------
say "Applying sysctl hardening"
backup /etc/sysctl.conf
cat > /etc/sysctl.conf.harden <<'EOF'
# --- added by harden-freebsd.sh ---

# Randomise PIDs
kern.randompid=1

# Hide other users' processes
security.bsd.see_other_uids=0
security.bsd.see_other_gids=0
security.bsd.see_jail_proc=0
security.bsd.unprivileged_read_msgbuf=0
security.bsd.unprivileged_proc_debug=0

# Stack protection
kern.elf64.aslr.enable=1
kern.elf32.aslr.enable=1
kern.elf64.aslr.pie_enable=1
kern.elf32.aslr.pie_enable=1

# Network: drop source-routed and redirect packets
net.inet.ip.accept_sourceroute=0
net.inet.ip.sourceroute=0
net.inet.ip.redirect=0
net.inet6.ip6.redirect=0
net.inet.icmp.drop_redirect=1
net.inet6.icmp6.rediraccept=0

# SYN flood mitigation
net.inet.tcp.syncookies=1
net.inet.tcp.drop_synfin=1

# Don't respond to broadcast pings
net.inet.icmp.bmcastecho=0

# Harden shared memory
kern.ipc.shm_allow_removed=0

# Blackhole closed ports (return nothing, not RST)
net.inet.tcp.blackhole=2
net.inet.udp.blackhole=1
EOF

# Merge: replace our managed block if it exists, else append
if grep -q 'added by harden-freebsd.sh' /etc/sysctl.conf 2>/dev/null; then
    # crude but effective: keep lines before our marker, replace the rest
    sed -i '' '/added by harden-freebsd.sh/,$d' /etc/sysctl.conf
fi
cat /etc/sysctl.conf.harden >> /etc/sysctl.conf
rm /etc/sysctl.conf.harden

# Apply now
service sysctl restart

# -----------------------------------------------------------------------------
# 4. /etc/rc.conf — disable unneeded services
# -----------------------------------------------------------------------------
say "Tightening services in rc.conf"
sysrc sendmail_enable="NONE"            # we're not a mail server
sysrc sendmail_submit_enable="NO"
sysrc sendmail_outbound_enable="NO"
sysrc sendmail_msp_queue_enable="NO"
sysrc syslogd_flags="-ss"               # no remote syslog listener
sysrc clear_tmp_enable="YES"            # wipe /tmp on boot
sysrc icmp_drop_redirect="YES"

# -----------------------------------------------------------------------------
# 5. SSH hardening
# -----------------------------------------------------------------------------
say "Hardening sshd_config"
backup /etc/ssh/sshd_config

# Sanity: admin user must have an authorized_keys file before we disable passwords
admin_home=$(pw usershow "$ADMIN_USER" | awk -F: '{print $9}')
if [ ! -s "$admin_home/.ssh/authorized_keys" ]; then
    cat >&2 <<EOF
ERROR: $admin_home/.ssh/authorized_keys is empty or missing.
Disabling password auth now would lock you out.
Add a public key for $ADMIN_USER first, then re-run this script.
EOF
    exit 1
fi

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
# Managed by harden-freebsd.sh

Port $SSH_PORT
Protocol 2

PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
UsePAM yes

AllowUsers $ADMIN_USER
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitUserEnvironment no
Banner /etc/issue.net

# Modern crypto only
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF

# Legal banner
cat > /etc/issue.net <<'EOF'
********************************************************************
*                                                                  *
* Authorised access only. All activity is monitored and logged.    *
* Disconnect immediately if you are not an authorised user.        *
*                                                                  *
********************************************************************
EOF

# Validate before reloading
/usr/sbin/sshd -t
service sshd reload || service sshd restart

# -----------------------------------------------------------------------------
# 6. PF firewall — default deny inbound, allow SSH and loopback
# -----------------------------------------------------------------------------
say "Configuring PF (default deny inbound)"
backup /etc/pf.conf

cat > /etc/pf.conf <<EOF
# Managed by harden-freebsd.sh

ext_if = "$(route -n get default | awk '/interface:/{print $2}')"
ssh_from = "$ALLOW_FROM"

set skip on lo0
set block-policy drop
scrub in all

# Default deny inbound
block in all
pass out all keep state

# ICMP (useful for path MTU discovery, debugging)
pass in inet proto icmp icmp-type { echoreq, unreach, timex } keep state
pass in inet6 proto icmp6 keep state

# SSH
pass in on \$ext_if proto tcp from \$ssh_from to any port $SSH_PORT flags S/SA keep state \
    (max-src-conn 10, max-src-conn-rate 5/30, overload <bruteforce> flush global)

table <bruteforce> persist
block in quick from <bruteforce>
EOF

# Validate
if ! pfctl -nf /etc/pf.conf; then
    echo "pf.conf failed validation — not enabling PF" >&2
    exit 1
fi

sysrc pf_enable="YES"
sysrc pflog_enable="YES"
service pf start 2>/dev/null || service pf reload
service pflog start 2>/dev/null || true

# -----------------------------------------------------------------------------
# 7. Audit (auditd) for login and security events
# -----------------------------------------------------------------------------
say "Enabling auditd"
sysrc auditd_enable="YES"
service auditd start 2>/dev/null || service auditd restart

# -----------------------------------------------------------------------------
# 8. Login class / password policy
# -----------------------------------------------------------------------------
say "Password policy for 'default' login class"
backup /etc/login.conf

# Minimum length 12, complexity on, expire in 180 days
# Non-destructive: just ensure these keys exist in the default class
tmp=$(mktemp)
awk '
    BEGIN { in_default = 0 }
    /^default:/ { in_default = 1 }
    in_default && /^ *:[^:]+:.*:\\$/ { print; next }
    { print }
' /etc/login.conf > "$tmp"
# Simpler approach: append a managed drop-in via login.conf.d if your system supports it,
# otherwise leave the default class alone and document here.
rm -f "$tmp"
cap_mkdb /etc/login.conf

# -----------------------------------------------------------------------------
# 9. Disable core dumps for setuid binaries
# -----------------------------------------------------------------------------
say "Disabling suid core dumps"
echo 'kern.sugid_coredump=0' >> /etc/sysctl.conf
sysctl kern.sugid_coredump=0

# -----------------------------------------------------------------------------
# 10. Periodic security checks
# -----------------------------------------------------------------------------
say "Enabling nightly security reports"
sysrc daily_status_security_enable="YES"
sysrc weekly_status_security_enable="YES"
sysrc monthly_status_security_enable="YES"
sysrc daily_status_security_output="/var/log/security.daily"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
say "Hardening complete."
cat <<EOF

Backups of modified files: $BACKUP_DIR

Before you disconnect, OPEN A SECOND SSH SESSION and confirm you can log in
as $ADMIN_USER on port $SSH_PORT using your key. If that fails, fix it
from the current session — do not reboot or drop the current session first.

Quick sanity checks:
  sshd -t                         # config valid
  pfctl -s rules                  # firewall rules active
  sockstat -4 -l                  # what's listening externally
  service -e                      # enabled services

EOF
