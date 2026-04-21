# Fedora Firewalls: The Essentials

Fedora uses **firewalld** as its firewall manager. Under the hood it's nftables (or iptables on older systems), but you interact with firewalld's higher-level concepts.

## The Core Concept: Zones

A **zone** is a trust level. You assign network interfaces (and/or source IPs) to zones, and each zone has its own rules for what's allowed.

This is the mental model: "Wi-Fi at home is *trusted*, but Wi-Fi at a coffee shop is *untrusted*." Zones let you apply different rules to each.

### Built-in zones, from most to least trusting

| Zone | Default behavior | Typical use |
|---|---|---|
| `trusted` | Accepts everything | VPN tunnels, loopback-equivalent |
| `home` | Accepts common home services (SSH, mDNS, Samba) | Home network |
| `internal` | Like home, for internal networks | Internal corporate |
| `work` | Accepts some services | Work network |
| `public` | Accepts only a few services | Default for unknown networks |
| `external` | Used for NAT gateway (router-like role) | When machine is acting as a router |
| `dmz` | Limited inbound, typical "DMZ host" posture | Servers in a DMZ |
| `block` | Rejects all incoming with ICMP message | "I'm here but go away" |
| `drop` | Silently drops all incoming | "Pretend I don't exist" |

Fedora also ships two custom zones:

- `FedoraWorkstation` — default on Fedora Workstation; permissive for desktop use
- `FedoraServer` — default on Fedora Server; more restrictive

## How traffic gets sorted into a zone

When a packet arrives, firewalld picks a zone by checking in this order:

1. **Source IP match** — if a zone has a matching source range, use that zone
2. **Interface match** — if a zone has the arriving interface bound, use that zone
3. **Default zone** — otherwise, use the default zone

Rules of that zone are then applied. This is why "which zone is active" matters so much — rules in zones with no interfaces or sources bound are simply never evaluated.

## Runtime vs Permanent — the #1 gotcha

firewalld has two config states:

- **Runtime** — live, in-memory. Changes take effect immediately. Lost on reload/reboot.
- **Permanent** — written to disk. Applied on reload/reboot, not immediately.

```bash
# Runtime (temporary, for testing)
sudo firewall-cmd --zone=public --add-service=http

# Permanent (written to disk, needs reload to activate)
sudo firewall-cmd --permanent --zone=public --add-service=http
sudo firewall-cmd --reload
```

**Rule of thumb:** always use `--permanent` and follow with `--reload`. Otherwise your rule disappears on reboot.

To check if runtime and permanent match:

```bash
sudo firewall-cmd --zone=<zone> --list-all                # runtime
sudo firewall-cmd --permanent --zone=<zone> --list-all    # permanent
```

Differences between the two are usually a sign someone forgot `--permanent`.

## Services vs Ports — two ways to allow traffic

**Services** are named bundles of ports/protocols. firewalld ships hundreds of predefined ones:

```bash
sudo firewall-cmd --get-services    # list all available
sudo firewall-cmd --info-service=ssh    # details of one
```

`ssh` is just a service that maps to TCP port 22. Using services is more readable than raw ports.

**Ports** are direct numeric rules:

```bash
sudo firewall-cmd --permanent --zone=public --add-port=8080/tcp
```

Use services when one exists, ports when you need something custom. Both work identically under the hood.

## Essential Commands — The Hard and Fast Reference

### See what's happening

```bash
# Which zones have interfaces/sources bound right now
sudo firewall-cmd --get-active-zones

# Default zone (for interfaces that don't match any zone)
sudo firewall-cmd --get-default-zone

# Full config of one zone
sudo firewall-cmd --zone=<zone> --list-all

# All zones at once
sudo firewall-cmd --list-all-zones

# Just the interfaces, services, or ports
sudo firewall-cmd --zone=<zone> --list-interfaces
sudo firewall-cmd --zone=<zone> --list-services
sudo firewall-cmd --zone=<zone> --list-ports
```

### Add rules

```bash
# Allow a named service
sudo firewall-cmd --permanent --zone=<zone> --add-service=<name>

# Allow a port
sudo firewall-cmd --permanent --zone=<zone> --add-port=<num>/<proto>

# Bind an interface to a zone
sudo firewall-cmd --permanent --zone=<zone> --add-interface=<iface>

# Trust traffic from a specific IP/subnet (via source match)
sudo firewall-cmd --permanent --zone=<zone> --add-source=<ip-or-cidr>

# Apply permanent changes
sudo firewall-cmd --reload
```

### Remove rules

Same as add, but `--remove-` instead of `--add-`:

```bash
sudo firewall-cmd --permanent --zone=<zone> --remove-service=<name>
sudo firewall-cmd --permanent --zone=<zone> --remove-port=<num>/<proto>
sudo firewall-cmd --permanent --zone=<zone> --remove-interface=<iface>
sudo firewall-cmd --reload
```

### Change defaults

```bash
# Change the default zone
sudo firewall-cmd --set-default-zone=<zone>

# Move an interface between zones
sudo firewall-cmd --permanent --zone=<new-zone> --change-interface=<iface>
sudo firewall-cmd --reload
```

## Advanced: Rich Rules

When services and ports aren't expressive enough (e.g. "allow SSH from only this subnet"):

```bash
sudo firewall-cmd --permanent --zone=public --add-rich-rule='
  rule family="ipv4" source address="192.168.1.0/24" service name="ssh" accept'
sudo firewall-cmd --reload
```

Rich rules can match by source, destination, service, port, log, limit rate, and more. Powerful but verbose. Avoid unless you actually need the flexibility.

## Advanced: Forwarding and Masquerading

**Masquerading** is NAT — source address rewriting so traffic from an internal network appears to come from this machine. Turn it on only if this machine is acting as a router/gateway:

```bash
sudo firewall-cmd --permanent --zone=<zone> --add-masquerade
```

For a typical desktop or single-purpose server, leave this **off**.

**Port forwarding** (redirecting incoming traffic to another machine/port):

```bash
sudo firewall-cmd --permanent --zone=<zone> \
  --add-forward-port=port=8080:proto=tcp:toport=80:toaddr=192.168.1.50
```

Also rare on a regular machine — usually you want this on your router, not on a Fedora host.

## The NetworkManager Connection

On Fedora (and most modern distros), NetworkManager decides which zone each interface belongs to, not firewalld directly. That's why you sometimes see a zone's permanent config with empty `interfaces:` even though the interface is clearly bound at runtime.

Check per-connection zone assignment:

```bash
nmcli -f connection.id,connection.zone connection show
```

Set one explicitly:

```bash
sudo nmcli connection modify "<connection-name>" connection.zone <zone>
sudo nmcli connection up "<connection-name>"
```

This is the proper way to persistently bind an interface to a zone on Fedora Workstation. It survives reboots and reconnects.

## Troubleshooting Playbook

When something doesn't work, check in this order:

```bash
# 1. Is firewalld running?
sudo systemctl status firewalld

# 2. Which zone is the interface in right now?
sudo firewall-cmd --get-active-zones

# 3. What does that zone allow?
sudo firewall-cmd --zone=<zone> --list-all

# 4. Is the service actually listening?
sudo ss -tulnp | grep <port>

# 5. Is traffic arriving at all?
sudo tcpdump -i any -n port <port>

# 6. Runtime vs permanent consistent?
sudo firewall-cmd --zone=<zone> --list-all
sudo firewall-cmd --permanent --zone=<zone> --list-all
```

Most real-world issues are one of:

- Rule added to runtime only, lost after reboot
- Rule added to wrong zone (inactive zone = rule never applied)
- Service not actually listening (firewall would let it through if it existed)
- Something upstream (router, ISP, CGNAT) blocking before packets arrive

## The Minimalist Hardening Template

For a typical Fedora desktop or small server that only needs specific services exposed:

```bash
# 1. Confirm active zone
sudo firewall-cmd --get-active-zones

# 2. Start clean: remove anything you didn't add deliberately
sudo firewall-cmd --zone=<active-zone> --list-services
sudo firewall-cmd --zone=<active-zone> --list-ports
# Review the output, remove what you don't need with --remove-service / --remove-port

# 3. Add only what you actually use
sudo firewall-cmd --permanent --zone=<active-zone> --add-service=dhcpv6-client
# (add other specific needs here)

sudo firewall-cmd --reload
```

For WireGuard setups specifically, bind `wg0` to the `trusted` zone — traffic that's already authenticated by cryptographic keys doesn't need further firewall scrutiny:

```bash
sudo firewall-cmd --permanent --zone=trusted --add-interface=wg0
sudo firewall-cmd --reload
```

## Key Mental Model

Remember these four things and you'll understand 90% of firewalld in practice:

1. **A zone is a trust level with its own rules.** Interfaces and source IPs get sorted into zones.
2. **Active zones matter, inactive ones don't.** A rule in a zone with no bound interfaces or sources is dead weight.
3. **`--permanent` or it didn't happen.** Always pair with `--reload`.
4. **NetworkManager controls interface-to-zone binding on Fedora.** Use `nmcli connection modify ... connection.zone` for persistence.

Everything else is just commands you can look up. These four concepts are what actually matter.

## Cheat Sheet

```bash
# Show state
firewall-cmd --get-active-zones
firewall-cmd --get-default-zone
firewall-cmd --zone=<z> --list-all

# Add (always permanent)
firewall-cmd --permanent --zone=<z> --add-service=<s>
firewall-cmd --permanent --zone=<z> --add-port=<n>/<p>
firewall-cmd --permanent --zone=<z> --add-interface=<i>
firewall-cmd --permanent --zone=<z> --add-source=<cidr>

# Remove
firewall-cmd --permanent --zone=<z> --remove-service=<s>
firewall-cmd --permanent --zone=<z> --remove-port=<n>/<p>

# Apply
firewall-cmd --reload

# Runtime vs permanent diff
firewall-cmd --zone=<z> --list-all                    # runtime
firewall-cmd --permanent --zone=<z> --list-all        # permanent

# NetworkManager zone binding
nmcli -f connection.id,connection.zone connection show
nmcli connection modify "<name>" connection.zone <z>
```

That's the whole thing. Firewalld isn't complicated once you grasp zones and the runtime/permanent split — everything else falls out of those two ideas.
