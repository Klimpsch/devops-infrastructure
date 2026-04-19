# WireGuard Quick Setup: Fedora ↔ Windows

Remote access VPN, SSH locked to tunnel. Tunnel subnet: `10.10.10.0/24` (server `.1`, client `.2`).

---

## Fedora Server

**1. Install**

```bash
sudo dnf install wireguard-tools -y
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

**4. Firewall**

```bash
sudo firewall-cmd --get-active-zones   # note your active zone
sudo firewall-cmd --permanent --zone=<active-zone> --add-port=51820/udp
sudo firewall-cmd --permanent --zone=trusted --add-interface=wg0
sudo firewall-cmd --reload
```

**5. Start tunnel**

```bash
sudo systemctl enable --now wg-quick@wg0
```

**6. Router**

Forward **UDP 51820** → Fedora LAN IP. Get your public IP with:

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
PublicKey = <Fedora server_public.key contents>
Endpoint = <your-public-ip-or-ddns>:51820
AllowedIPs = 10.10.10.0/24
PersistentKeepalive = 25
```

Save.

**4. Paste Windows public key into Fedora `wg0.conf` `[Peer] PublicKey` line, then:**

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
sudo firewall-cmd --permanent --zone=<active-zone> --remove-service=ssh
sudo firewall-cmd --reload
```

**Optional — key auth from Windows:**

```powershell
ssh-keygen -t ed25519
ssh-copy-id <user>@10.10.10.1
```

Then on Fedora, edit `/etc/ssh/sshd_config`:

```
PasswordAuthentication no
PermitRootLogin no
```

```bash
sudo systemctl reload sshd
```
