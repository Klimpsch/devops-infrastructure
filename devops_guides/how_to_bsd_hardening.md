# As root on the target FreeBSD host:
# 1. Create your admin user FIRST and add your SSH public key
pw useradd admin -m -s /bin/sh -G wheel
passwd admin
mkdir -p /home/admin/.ssh
# paste your public key into authorized_keys
vi /home/admin/.ssh/authorized_keys
chown -R admin:admin /home/admin/.ssh
chmod 700 /home/admin/.ssh
chmod 600 /home/admin/.ssh/authorized_keys

# 2. Download and review the script
# (read it — understand every section)

# 3. Run it, passing your config
ADMIN_USER=admin SSH_PORT=22 ALLOW_FROM=10.0.0.0/8 TIMEZONE=Australia/Sydney \
  sh harden-freebsd.sh
