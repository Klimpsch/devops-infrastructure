#!/usr/bin/env bash
#
# setup-wireguard-fedora.sh - Automate WireGuard server setup on Fedora
#
# Sets up WireGuard as a VPN server on Fedora. Generates keys, creates config,
# configures firewalld, and starts the service. Does not handle the client side.
#
# Usage:
#   sudo ./setup-wireguard-fedora.sh
#   sudo ./setup-wireguard-fedora.sh --subnet 10.20.30.0/24 --port 51820
#   sudo ./setup-wireguard-fedora.sh --add-peer <peer-public-key>

set -euo pipefail

# --- Defaults ---
INTERFACE="wg0"
PORT="51820"
SUBNET="10.10.10.0/24"
SERVER_IP="10.10.10.1"
CLIENT_IP_BASE="10.10.10"  # clients get .2, .3, ...
CONFIG_DIR="/etc/wireguard"
ADD_PEER_KEY=""
PEER_ALLOWED_IP=""
FORCE=false

# --- Helpers ---

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
ok() { echo "[✓] $*"; }

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Sets up WireGuard server on Fedora with firewalld rules.

Options:
  --interface <name>      WireGuard interface name (default: wg0)
  --port <port>           UDP port to listen on (default: 51820)
  --subnet <cidr>         VPN subnet (default: 10.10.10.0/24)
  --server-ip <ip>        Server's IP in the VPN (default: 10.10.10.1)
  --add-peer <pubkey>     Add a peer's public key to existing config
  --peer-ip <ip>          IP to assign the peer (default: next available)
  --force                 Overwrite existing config without prompt
  --help                  Show this message

Examples:
  # Fresh install with defaults
  sudo $0

  # Custom subnet and port
  sudo $0 --subnet 10.20.30.0/24 --server-ip 10.20.30.1 --port 51821

  # Add a client public key to existing setup
  sudo $0 --add-peer 'abc123...=' --peer-ip 10.10.10.2

Notes:
  - Must run as root (uses sudo internally where needed).
  - Firewall rules added to the active firewalld zone.
  - Port forwarding on your router must be configured separately.
EOF
    exit 0
}

# --- Parse arguments ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interface)    INTERFACE="$2"; shift 2 ;;
        --port)         PORT="$2"; shift 2 ;;
        --subnet)       SUBNET="$2"; shift 2 ;;
        --server-ip)    SERVER_IP="$2"; shift 2 ;;
        --add-peer)     ADD_PEER_KEY="$2"; shift 2 ;;
        --peer-ip)      PEER_ALLOWED_IP="$2"; shift 2 ;;
        --force)        FORCE=true; shift ;;
        --help|-h)      usage ;;
        *)              die "Unknown argument: $1. Use --help for usage." ;;
    esac
done

CONFIG_FILE="$CONFIG_DIR/${INTERFACE}.conf"
SERVER_PRIV_KEY_FILE="$CONFIG_DIR/server_private.key"
SERVER_PUB_KEY_FILE="$CONFIG_DIR/server_public.key"

# --- Pre-flight checks ---

[[ $EUID -ne 0 ]] && die "Must run as root. Re-run with sudo."

if ! grep -qi fedora /etc/os-release 2>/dev/null; then
    warn "This script is designed for Fedora. Continuing anyway..."
fi

# --- Mode: Add peer to existing config ---

add_peer() {
    [[ ! -f "$CONFIG_FILE" ]] && die "Config $CONFIG_FILE not found. Run setup first."

    # Validate public key format (basic check: 44 chars ending in =)
    if [[ ! "$ADD_PEER_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        die "Invalid public key format. Expected 44 chars ending in '=' (base64)."
    fi

    # Check if peer already exists
    if grep -q "$ADD_PEER_KEY" "$CONFIG_FILE"; then
        die "Peer with this public key already exists in $CONFIG_FILE."
    fi

    # Auto-assign peer IP if not provided
    if [[ -z "$PEER_ALLOWED_IP" ]]; then
        # Find highest existing peer IP and add 1
        last_octet=$(grep -oP 'AllowedIPs = \d+\.\d+\.\d+\.\K\d+' "$CONFIG_FILE" | sort -n | tail -1 || echo "1")
        next_octet=$((last_octet + 1))
        PEER_ALLOWED_IP="${CLIENT_IP_BASE}.${next_octet}"
        info "Auto-assigned peer IP: $PEER_ALLOWED_IP"
    fi

    info "Adding peer to $CONFIG_FILE..."
    cat >> "$CONFIG_FILE" <<EOF

[Peer]
PublicKey = $ADD_PEER_KEY
AllowedIPs = ${PEER_ALLOWED_IP}/32
EOF

    info "Restarting WireGuard..."
    systemctl restart "wg-quick@${INTERFACE}"

    ok "Peer added. Server config:"
    wg show "$INTERFACE"
    exit 0
}

if [[ -n "$ADD_PEER_KEY" ]]; then
    add_peer
fi

# --- Mode: Fresh setup ---

info "=== WireGuard Fedora Server Setup ==="
echo "Interface:     $INTERFACE"
echo "Port:          $PORT"
echo "VPN subnet:    $SUBNET"
echo "Server IP:     $SERVER_IP"
echo "Config:        $CONFIG_FILE"
echo

# Check for existing config
if [[ -f "$CONFIG_FILE" && "$FORCE" != "true" ]]; then
    warn "Config already exists: $CONFIG_FILE"
    read -r -p "Overwrite? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { info "Aborted. Use --add-peer to add clients to existing config."; exit 0; }
fi

# --- Install WireGuard ---

if ! command -v wg >/dev/null 2>&1; then
    info "Installing wireguard-tools..."
    dnf install -y wireguard-tools || die "Failed to install wireguard-tools"
else
    ok "wireguard-tools already installed"
fi

# --- Generate keys ---

info "Generating server keys..."
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

umask 077
wg genkey | tee "$SERVER_PRIV_KEY_FILE" | wg pubkey > "$SERVER_PUB_KEY_FILE"
chmod 600 "$SERVER_PRIV_KEY_FILE"
chmod 644 "$SERVER_PUB_KEY_FILE"

SERVER_PRIV_KEY=$(cat "$SERVER_PRIV_KEY_FILE")
SERVER_PUB_KEY=$(cat "$SERVER_PUB_KEY_FILE")

ok "Keys generated"

# --- Write config ---

info "Writing $CONFIG_FILE..."

# Extract CIDR suffix from subnet (e.g. 24 from 10.10.10.0/24)
CIDR_SUFFIX="${SUBNET##*/}"

cat > "$CONFIG_FILE" <<EOF
[Interface]
Address = ${SERVER_IP}/${CIDR_SUFFIX}
ListenPort = $PORT
PrivateKey = $SERVER_PRIV_KEY

# Add peers below. Use --add-peer to add them via this script.
# Manual format:
# [Peer]
# PublicKey = <client public key>
# AllowedIPs = 10.10.10.2/32
EOF

chmod 600 "$CONFIG_FILE"
ok "Config written"

# --- Configure firewalld ---

info "Configuring firewalld..."

if ! systemctl is-active --quiet firewalld; then
    warn "firewalld is not running. Starting it..."
    systemctl enable --now firewalld
fi

# Get the active zone (exclude trusted zone which we configure separately)
ACTIVE_ZONE=$(firewall-cmd --get-active-zones | grep -B1 interfaces | grep -v -- '--' | grep -v interfaces | grep -v '^$' | grep -v '^trusted' | head -1 || true)

if [[ -z "$ACTIVE_ZONE" ]]; then
    ACTIVE_ZONE=$(firewall-cmd --get-default-zone)
    warn "Could not detect active zone; using default: $ACTIVE_ZONE"
fi

info "Active zone detected: $ACTIVE_ZONE"

# Add WireGuard port
firewall-cmd --permanent --zone="$ACTIVE_ZONE" --add-port="${PORT}/udp" >/dev/null
firewall-cmd --permanent --zone=trusted --add-interface="$INTERFACE" >/dev/null
firewall-cmd --reload >/dev/null

ok "Firewalld: ${PORT}/udp allowed in $ACTIVE_ZONE, $INTERFACE trusted"

# --- Start WireGuard ---

info "Starting WireGuard service..."
systemctl enable --now "wg-quick@${INTERFACE}"

sleep 1

if systemctl is-active --quiet "wg-quick@${INTERFACE}"; then
    ok "WireGuard service is running"
else
    die "WireGuard service failed to start. Check: journalctl -u wg-quick@${INTERFACE}"
fi

# --- Verification ---

echo
info "=== Verification ==="
echo
echo "Interface status:"
wg show "$INTERFACE"
echo
echo "Listening ports:"
ss -ulnp | grep ":${PORT}" || warn "Port not listening?"
echo

# --- Gather info for user ---

LAN_IP=$(ip -4 addr show | awk '/inet / && $2 !~ /^127|^10\.10\.10/ {print $2; exit}' | cut -d/ -f1)
PUBLIC_IP=$(curl -s -4 --max-time 5 ifconfig.me || echo "UNKNOWN (check internet)")

# --- Summary ---

cat <<EOF

================================================================
 WireGuard Fedora setup complete
================================================================

Server public key (give to clients):
  $SERVER_PUB_KEY

Server details for client config:
  Endpoint    = ${PUBLIC_IP}:${PORT}
  AllowedIPs  = ${SUBNET}    (or 0.0.0.0/0 for full-tunnel)

Router port forward required:
  Forward UDP ${PORT} on your router's public IP to:
  ${LAN_IP}:${PORT}   (this machine's LAN IP)

Add a client to this server:
  sudo $0 --add-peer <client-public-key>

Optional: lock SSH to the tunnel (removes SSH from LAN):
  sudo firewall-cmd --permanent --zone=${ACTIVE_ZONE} --remove-service=ssh
  sudo firewall-cmd --reload

Verify the tunnel from a client:
  1. Add this server's public key to the client config
  2. Add the client's public key here via --add-peer
  3. Activate the tunnel on the client
  4. ping ${SERVER_IP} from the client

Config file:     $CONFIG_FILE
Server pubkey:   $SERVER_PUB_KEY_FILE
Server privkey:  $SERVER_PRIV_KEY_FILE (keep secret!)

EOF

if [[ "$PUBLIC_IP" == "UNKNOWN (check internet)" ]]; then
    warn "Could not detect public IP. Run 'curl -4 ifconfig.me' manually."
fi

# CGNAT warning
if [[ -n "$LAN_IP" && -n "$PUBLIC_IP" && "$PUBLIC_IP" != "UNKNOWN"* ]]; then
    # Rough check: if public IP starts with 10., 100.64-127., 172.16-31., 192.168., likely CGNAT or LAN
    if [[ "$PUBLIC_IP" =~ ^(10\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])|172\.(1[6-9]|2[0-9]|3[01])|192\.168\.) ]]; then
        warn "Public IP appears to be in private/CGNAT range: $PUBLIC_IP"
        warn "Port forwarding may not work. Consider Tailscale if behind CGNAT."
    fi
fi

ok "Setup complete."
