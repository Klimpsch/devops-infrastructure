#!/bin/bash

set -e

echo "========================================"
echo "  Network Lab Environment Setup Script  "
echo "========================================"

# ── Virtualization ────────────────────────────────────────────────
echo ""
echo "[1/7] Installing virtualization packages..."
sudo dnf install -y @virtualization
sudo dnf install -y libxml2-devel libxslt-devel

echo "      Enabling libvirtd..."
sudo systemctl enable --now libvirtd

echo "      Adding $(whoami) to libvirt group..."
sudo usermod -aG libvirt "$(whoami)"

echo "      Setting CPU governor to performance..."
echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# ── Development Tools ─────────────────────────────────────────────
echo ""
echo "[2/7] Installing development tools..."
sudo dnf install -y @development-tools
sudo dnf install -y python3-devel
sudo dnf install -y pipx

# ── Python Packages ───────────────────────────────────────────────
echo ""
echo "[3/7] Installing Python networking packages..."
pip install --upgrade \
    paramiko \
    netmiko \
    scrapli \
    PyYAML \
    pydantic \
    ncclient \
    scrapli-netconf \
    scapy \
    netaddr \
    nornir \
    nornir-netmiko \
    nornir-utils \
    napalm

echo "      Installing Junos eznc..."
pip install junos-eznc

# ── Firewall ──────────────────────────────────────────────────────
echo ""
echo "[4/7] Configuring firewall..."
sudo firewall-cmd --add-service=ssh --permanent
sudo firewall-cmd --reload

# ── SSH Config ────────────────────────────────────────────────────
echo ""
echo "[5/7] SSH config..."
if [ -r /dev/tty ] && [ -t 1 ]; then
    echo "      Opening sshd_config for manual editing."
    echo "      Uncomment any settings you need, then save and exit."
    read -rp "      Press Enter to open sshd_config in vim..." < /dev/tty
    sudo vim /etc/ssh/sshd_config < /dev/tty
    echo "      Restarting sshd..."
    sudo systemctl restart sshd
else
    echo "      Non-interactive run — skipping sshd_config edit."
    echo "      Review it manually after this script finishes:"
    echo "          sudo vim /etc/ssh/sshd_config && sudo systemctl restart sshd"
fi

# ── libvirt Permissions ───────────────────────────────────────────
echo ""
echo "[6/7] Setting libvirt image directory permissions..."
sudo chmod 771 /var/lib/libvirt/images
sudo chown root:libvirt /var/lib/libvirt/images

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo "[7/7] Done!"
echo ""
echo "  ⚠  Group changes (libvirt) require a logout/login to take effect."
echo "     Run: newgrp libvirt  (for this session only)"
echo ""
