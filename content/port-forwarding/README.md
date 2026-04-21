# Port forwarding — Fedora host :9090 → VM :9090

Forward inbound traffic on the Fedora host's port 9090 to a VM on the libvirt
NAT network, so the VM's service is reachable from the LAN (and through
WireGuard) as `<fedora-host-ip>:9090`.

## Assumptions

- Fedora host with firewalld (default on Fedora)
- Libvirt default network (`virbr0`, `192.168.122.0/24`)
- VM running a service on `:9090`, bound to `0.0.0.0` (not `127.0.0.1`)

## Variables

```bash
VM_IP=192.168.122.10      # target VM's libvirt IP
PORT=9090
```

## 1. Enable IP forwarding

```bash
sudo sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-forward.conf
```

## 2. Identify the zones that need the rule

Traffic arrives on different zones depending on where the client is:

```bash
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --get-zone-of-interface=virbr0     # usually: libvirt
sudo firewall-cmd --get-zone-of-interface=wg0        # if WireGuard is up
```

Typical layout:

| Interface | Zone |
|---|---|
| `wlp*` / `eth*` | `FedoraWorkstation` |
| `virbr0` | `libvirt` |
| `wg0` | `trusted` (or a custom zone) |

Add the forward to every zone the traffic might enter through. `trusted` doesn't need it — trusted permits everything.

## 3. Add the port forward

```bash
sudo firewall-cmd --permanent --zone=FedoraWorkstation \
  --add-forward-port=port=$PORT:proto=tcp:toport=$PORT:toaddr=$VM_IP

sudo firewall-cmd --permanent --zone=libvirt \
  --add-forward-port=port=$PORT:proto=tcp:toport=$PORT:toaddr=$VM_IP
```

Enable NAT on the libvirt zone so return traffic flows correctly:

```bash
sudo firewall-cmd --permanent --zone=libvirt --add-masquerade
sudo firewall-cmd --reload
```

## 4. Verify

```bash
sudo firewall-cmd --zone=FedoraWorkstation --list-forward-ports
sudo firewall-cmd --zone=libvirt --list-forward-ports
sudo firewall-cmd --zone=libvirt --query-masquerade
```

Test from the host itself (proves the VM is listening):

```bash
curl -sI http://$VM_IP:$PORT
```

Test from another device on the LAN, or a WireGuard client:

```bash
curl -sI http://<fedora-host-ip>:$PORT
```

Both should return headers, not "connection refused."

## Remove the forward

```bash
sudo firewall-cmd --permanent --zone=FedoraWorkstation \
  --remove-forward-port=port=$PORT:proto=tcp:toport=$PORT:toaddr=$VM_IP

sudo firewall-cmd --permanent --zone=libvirt \
  --remove-forward-port=port=$PORT:proto=tcp:toport=$PORT:toaddr=$VM_IP

sudo firewall-cmd --reload
```

## Troubleshooting

**Connection refused from LAN/WireGuard, works from Fedora host.**
Firewall zone for the inbound interface doesn't have the rule. Re-check
step 2 — WireGuard especially, since `wg0` isn't always in `trusted`.

**Connection times out.**
Masquerade missing on the libvirt zone (step 3's last command), or
`net.ipv4.ip_forward` is 0. Confirm with `sysctl net.ipv4.ip_forward`.

**Works from LAN, not from WireGuard.**
The service on the VM may be binding only to `127.0.0.1`. Check on the VM:

```bash
# Linux guest
ss -tlnp | grep :9090
# Windows guest (PowerShell)
Get-NetTCPConnection -LocalPort 9090
```

If it's bound to `127.0.0.1`, change the service config to listen on
`0.0.0.0` (or the VM's external NIC) and restart it.

**WireGuard client can reach the tunnel but not the forwarded port.**
Check `AllowedIPs` on the client `[Peer]` block includes the Fedora host's
LAN subnet — e.g. `AllowedIPs = 10.10.0.0/24, 192.168.0.0/24`.
