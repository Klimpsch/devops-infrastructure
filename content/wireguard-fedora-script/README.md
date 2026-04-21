# WireGuard Fedora Setup Script

Automates WireGuard server installation and configuration on Fedora. Handles installation, key generation, config creation, firewalld rules, and service startup.

## What it does

1. Installs `wireguard-tools` if missing
2. Generates server keypair in `/etc/wireguard/`
3. Creates `/etc/wireguard/wg0.conf` (or your chosen interface name)
4. Adds firewalld rules: WireGuard port to active zone, interface to trusted zone
5. Enables and starts `wg-quick@wg0` systemd service
6. Prints everything needed for client config (server public key, endpoint, etc.)

## What it doesn't do

- **Router port forwarding** — must be done manually in your router's admin page
- **Windows/client setup** — this is server-side only
- **Dynamic DNS** — if you need DDNS, set that up separately

## Usage

**Basic setup (defaults: wg0, port 51820, subnet 10.10.10.0/24):**

```bash
sudo ./setup-wireguard-fedora.sh
```

**Custom settings:**

```bash
sudo ./setup-wireguard-fedora.sh \
    --interface wg0 \
    --port 51820 \
    --subnet 10.20.30.0/24 \
    --server-ip 10.20.30.1
```

**Add a client peer to existing config:**

```bash
sudo ./setup-wireguard-fedora.sh --add-peer 'abc123...XYZ='
```

Script auto-assigns the next free IP in your subnet. Override with `--peer-ip`:

```bash
sudo ./setup-wireguard-fedora.sh --add-peer 'abc123...=' --peer-ip 10.10.10.5
```

**Overwrite existing setup without prompting:**

```bash
sudo ./setup-wireguard-fedora.sh --force
```

## Options

| Option | Default | Description |
|---|---|---|
| `--interface` | `wg0` | WireGuard interface name |
| `--port` | `51820` | UDP listen port |
| `--subnet` | `10.10.10.0/24` | VPN subnet |
| `--server-ip` | `10.10.10.1` | Server's IP within VPN |
| `--add-peer <key>` | — | Add peer public key to existing config |
| `--peer-ip <ip>` | auto | IP for the peer being added |
| `--force` | false | Skip overwrite confirmation |

## Typical Workflow

```bash
# 1. Set up the server
sudo ./setup-wireguard-fedora.sh

# 2. Note the server public key from the output

# 3. On your Windows/phone/other client:
#    - Install WireGuard
#    - Create a new tunnel (auto-generates client keypair)
#    - Copy the client's public key
#    - Fill in client config with the server public key and endpoint

# 4. Back on Fedora, add the client's public key:
sudo ./setup-wireguard-fedora.sh --add-peer '<client-public-key>'

# 5. On the client, activate the tunnel
# 6. From client: ping 10.10.10.1

# 7. Configure your router: forward UDP 51820 to this machine's LAN IP
```

## Output

After a successful run, the script prints:

- **Server public key** — paste into client `[Peer] PublicKey =`
- **Endpoint** — your public IP and port, paste into client `Endpoint =`
- **Tunnel subnet** — for client `AllowedIPs =`
- **LAN IP** — for configuring router port forwarding
- **Config file paths**

## Client Config Template

Use the server info in a client config like this:

```ini
[Interface]
PrivateKey = <client's auto-generated private key>
Address = 10.10.10.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = <paste server public key here>
Endpoint = <public-ip-or-ddns>:51820
AllowedIPs = 10.10.10.0/24
PersistentKeepalive = 25
```

Then run `sudo ./setup-wireguard-fedora.sh --add-peer '<client public key>'` on the server.

## Verification

Script prints verification info automatically, but you can run manually:

```bash
# WireGuard status
sudo wg show

# Service status
sudo systemctl status wg-quick@wg0

# Interface
ip -brief addr | grep wg0

# Port listening
sudo ss -ulnp | grep 51820

# Firewall
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --zone=<active-zone> --list-all
sudo firewall-cmd --zone=trusted --list-all
```

## Troubleshooting

**"Must run as root"**: re-run with `sudo`.

**"Failed to install wireguard-tools"**: check internet connection, try `sudo dnf check-update` first.

**Service fails to start**: check `sudo journalctl -u wg-quick@wg0 -n 50`. Usually a key issue or port conflict.

**Firewalld not running**: script starts it automatically, but if it fails, enable manually: `sudo systemctl enable --now firewalld`.

**Client can't connect**:
- Verify the server public key in client config matches `cat /etc/wireguard/server_public.key`
- Verify client's public key was added via `--add-peer`
- Check router port forwarding
- Run `sudo tcpdump -i any -n udp port 51820` on server while client attempts connection

**CGNAT warning shown**: your public IP is in a private/CGNAT range, meaning you don't have a directly reachable public IP. Port forwarding won't work. Use Tailscale instead for such situations.

**Config overwritten accidentally**: the old config isn't backed up automatically. Be careful with `--force`. For safety, keep copies of working configs elsewhere.

## Security Notes

- Private keys are stored with `chmod 600` in `/etc/wireguard/` (root-only)
- The script's main risk is the output of a failed run potentially leaving keys on disk — check `/etc/wireguard/` after errors
- No passwords are used; WireGuard's security comes from the key pairs
- The server's private key should never leave the server
- Clients generate their own private keys and only share their public keys
- If a client is lost/compromised, remove its `[Peer]` block from `wg0.conf` and restart the service

## Uninstall

To fully remove WireGuard:

```bash
sudo systemctl disable --now wg-quick@wg0
sudo firewall-cmd --permanent --zone=trusted --remove-interface=wg0
sudo firewall-cmd --permanent --zone=<active-zone> --remove-port=51820/udp
sudo firewall-cmd --reload
sudo rm -rf /etc/wireguard
sudo dnf remove wireguard-tools -y
```

## Reference

- WireGuard docs: [wireguard.com](https://www.wireguard.com/)
- Fedora WireGuard wiki: search Fedora documentation
- Full guide: see `wireguard-ubuntu-guide.md` or `wireguard-setup-guide.md` (Fedora)
