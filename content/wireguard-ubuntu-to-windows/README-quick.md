# WireGuard Quick Setup: Ubuntu ↔ Windows

Remote access VPN, SSH locked to tunnel. Tunnel subnet: `10.10.10.0/24` (server `.1`, client `.2`).

---

## Ubuntu Server

**1. Install**

```bash
sudo apt update
sudo apt install wireguard -y
```

**2. Generate keys**

```bash
cd /etc/wireguard
sudo sh -c 'umask 077; wg genkey | tee server_private.key | wg pubkey > server_public.key'
```

**3. Create `/etc/wireguard/wg0.conf`**

```ini
[Interface]
Address = 10.10.10.1/24
ListenPort = 51820
PrivateKey = <server_private.key contents>

[Peer]
PublicKey = <Windows client public key — fill in later>
AllowedIPs = 10.10.10.2/32
```

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
```

**4. Firewall (UFW)**

```bash
sudo ufw allow 51820/udp
sudo ufw allow in on wg0
sudo ufw enable
```

**5. Start tunnel**

```bash
sudo systemctl enable --now wg-quick@wg0
```

**6. Router**

Forward **UDP 51820** → Ubuntu LAN IP. Get your public IP with:

```bash
curl -4 ifconfig.me
```

---

## Windows Client

**1. Install** from [wireguard.com/install](https://www.wireguard.com/install/)

**2. Add Tunnel → Add empty tunnel** (auto-generates keypair, copy the public key shown)

**3. Fill in config:**

```ini
[Interface]
PrivateKey = <leave auto-generated>
Address = 10.10.10.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = <Ubuntu server_public.key contents>
Endpoint = <your-public-ip-or-ddns>:51820
AllowedIPs = 10.10.10.0/24
PersistentKeepalive = 25
```

Save.

**4. Paste Windows public key into Ubuntu `wg0.conf` `[Peer] PublicKey` line, then:**

```bash
sudo systemctl restart wg-quick@wg0
```

**5. Click Activate in Windows WireGuard GUI**

**6. Test:**

```powershell
ping 10.10.10.1
ssh <user>@10.10.10.1
```

---

## Lock SSH to Tunnel

```bash
sudo ufw delete allow ssh
sudo ufw delete allow 22/tcp
```

**Optional — key auth from Windows:**

```powershell
ssh-keygen -t ed25519
ssh-copy-id <user>@10.10.10.1
```

Then on Ubuntu, edit `/etc/ssh/sshd_config`:

```
PasswordAuthentication no
PermitRootLogin no
```

```bash
sudo systemctl reload ssh
```
