# Ubuntu Firewalls: The Essentials

Ubuntu ships **UFW (Uncomplicated Firewall)** as its default firewall manager. Under the hood it's iptables/nftables — UFW is a friendlier front-end designed to make common tasks simple.

UFW is fundamentally different from firewalld (Fedora/RHEL's default): it has **no zones**. Rules are global and applied in order. Simpler mental model, less flexibility, but enough for most real-world needs.

## The Core Concept: Rules in a List

UFW maintains an ordered list of rules. When a packet arrives, UFW checks each rule top-to-bottom until one matches, then applies that rule's action (allow/deny/reject).

If no rule matches, the **default policy** applies. Typical defaults:

- **Incoming:** deny — block everything not explicitly allowed
- **Outgoing:** allow — let the system talk to the internet freely
- **Forwarding:** deny — don't act as a router

This is the "deny by default, allow by exception" model. You open only the ports/services you explicitly need.

## Rule Actions

| Action | Meaning |
|---|---|
| `allow` | Permit traffic |
| `deny` | Silently drop traffic (sender sees a timeout) |
| `reject` | Drop traffic with ICMP rejection (sender sees "connection refused") |
| `limit` | Allow, but rate-limit connection attempts (useful against SSH brute-force) |

`deny` is stealthier; `reject` is more polite. Most setups use `deny`.

## Essential Commands — The Hard and Fast Reference

### See what's happening

```bash
# Status and rules
sudo ufw status
sudo ufw status verbose         # includes default policies and logging
sudo ufw status numbered        # rules numbered for easy deletion

# List available app profiles
sudo ufw app list
sudo ufw app info <profile>
```

### Basic allow/deny

```bash
# Allow a port (TCP by default if unspecified)
sudo ufw allow 22
sudo ufw allow 22/tcp
sudo ufw allow 51820/udp

# Allow a service by name (uses /etc/services mapping)
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https

# Allow an app profile
sudo ufw allow OpenSSH

# Deny something
sudo ufw deny 23/tcp
```

### Restrict by source

```bash
# Allow SSH only from a specific IP
sudo ufw allow from 192.168.1.100 to any port 22

# Allow SSH from a subnet
sudo ufw allow from 192.168.1.0/24 to any port 22

# Allow anything from a trusted IP
sudo ufw allow from 10.0.0.5
```

### Restrict by interface

```bash
# Allow all traffic on a specific interface (e.g. VPN tunnel)
sudo ufw allow in on wg0

# Allow a port only on a specific interface
sudo ufw allow in on eth0 to any port 80
```

### Rate limiting (anti-brute-force)

```bash
# Limits to 6 connection attempts per 30 seconds per source IP
sudo ufw limit ssh
sudo ufw limit 22/tcp
```

Useful if SSH must be internet-exposed.

### Remove rules

```bash
# By rule specification (exact inverse of how you added it)
sudo ufw delete allow 22/tcp
sudo ufw delete allow ssh

# By rule number (often easier)
sudo ufw status numbered
sudo ufw delete 3            # deletes rule #3
```

### Enable, disable, reset

```bash
sudo ufw enable              # activates UFW, applies rules
sudo ufw disable             # stops UFW, flushes rules from kernel
sudo ufw reset               # wipes all rules, back to factory default
sudo ufw reload              # re-applies rules (rare to need)
```

### Change defaults

```bash
# Default policy for new incoming traffic
sudo ufw default deny incoming
sudo ufw default allow incoming    # don't do this on an exposed machine

# Default policy for outgoing
sudo ufw default allow outgoing

# Default policy for forwarding
sudo ufw default deny routed
```

## App Profiles

UFW supports named profiles for common apps, stored in `/etc/ufw/applications.d/`. Many packages register their own profiles on install.

```bash
sudo ufw app list               # see available profiles
sudo ufw app info 'Nginx Full'  # details
sudo ufw allow 'Nginx Full'     # allow by profile name
```

Common profiles you'll see: `OpenSSH`, `Apache`, `Apache Full`, `Apache Secure`, `Nginx HTTP`, `Nginx HTTPS`, `Nginx Full`, `CUPS`.

Profiles are just readable shortcuts for ports. Using them is purely stylistic.

## Logging

```bash
# Turn logging on (off, low, medium, high, full)
sudo ufw logging on
sudo ufw logging medium

# Logs go to /var/log/ufw.log
sudo tail -f /var/log/ufw.log
```

`low` logs blocked packets only. `medium` adds allowed rate-limited. `high` adds all. `full` is verbose enough to fill disks — use only for active debugging.

## Rule Order Matters

UFW processes rules top to bottom and stops at the first match. This matters when you have overlapping rules:

```bash
sudo ufw allow from 10.0.0.0/8 to any port 22      # rule 1
sudo ufw deny 22                                    # rule 2
```

In this example, anyone from `10.0.0.0/8` can SSH (rule 1 matches first and allows), but everyone else is denied (rule 2).

To insert a rule at a specific position:

```bash
sudo ufw insert 1 allow from 192.168.1.100 to any port 22
```

`1` means "put this at position 1 (top of the list)."

## IPv4 and IPv6

By default UFW creates matching IPv4 and IPv6 rules — you'll see duplicate-looking entries in `ufw status`, one for each stack. This is expected.

If you want to disable IPv6 rules entirely, edit `/etc/default/ufw`:

```
IPV6=no
```

Then `sudo ufw reload`. Rarely needed.

## Advanced: Editing Raw Rules

For things UFW can't express via its CLI (complex matches, custom chains), edit the underlying files:

- `/etc/ufw/before.rules` — iptables rules applied *before* UFW's user rules
- `/etc/ufw/after.rules` — applied *after*
- `/etc/ufw/user.rules` — generated from UFW commands; don't edit directly

For NAT/masquerading, uncomment the `*nat` block in `/etc/ufw/before.rules` and add:

```
-A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE
```

Then enable forwarding in `/etc/ufw/sysctl.conf`:

```
net/ipv4/ip_forward=1
```

Rarely needed for a typical desktop or single-service server.

## Troubleshooting Playbook

When something doesn't work, check in this order:

```bash
# 1. Is UFW running?
sudo ufw status

# 2. What rules are active?
sudo ufw status verbose
sudo ufw status numbered

# 3. Is the service actually listening?
sudo ss -tulnp | grep <port>

# 4. Is traffic arriving at all?
sudo tcpdump -i any -n port <port>

# 5. Check UFW logs for drops
sudo tail -f /var/log/ufw.log
```

Most real-world issues are one of:

- Rule added but UFW never enabled (`sudo ufw status` says `inactive`)
- Service not actually listening (UFW would allow through if the service existed)
- Rule order wrong — a deny higher up blocks what a later allow would permit
- Something upstream (router, ISP, CGNAT) blocking before packets arrive

## The Minimalist Hardening Template

For a typical Ubuntu desktop or small server:

```bash
# 1. Set defaults: deny incoming, allow outgoing
sudo ufw default deny incoming
sudo ufw default allow outgoing

# 2. Allow only what you need — examples:
sudo ufw allow ssh                      # or: sudo ufw limit ssh
sudo ufw allow 51820/udp                # WireGuard
sudo ufw allow in on wg0                # trust tunnel traffic

# 3. Enable
sudo ufw enable

# 4. Verify
sudo ufw status verbose
```

For WireGuard setups specifically, allow the interface itself — traffic through `wg0` is already authenticated by cryptographic keys:

```bash
sudo ufw allow in on wg0
```

This means any service listening on Ubuntu (SSH, web, etc.) is reachable via the tunnel, without opening those ports to the internet.

## UFW vs firewalld — Quick Comparison

| Aspect | UFW (Ubuntu) | firewalld (Fedora/RHEL) |
|---|---|---|
| Model | Flat rule list | Zones with rule sets |
| Default incoming | deny | varies by zone |
| Runtime vs permanent | one state (permanent) | two states |
| Command style | `ufw allow ssh` | `firewall-cmd --add-service=ssh` |
| Complexity | low | higher |
| Best for | simple server/desktop | multi-interface/complex networks |

If you know firewalld, UFW will feel simpler and more limited. If you're coming from UFW, firewalld has more power but more concepts to learn.

## Key Mental Model

Remember these four things and you'll understand 90% of UFW in practice:

1. **Rules are a flat, ordered list.** No zones. Top-to-bottom, first match wins.
2. **Default-deny incoming is the norm.** You open only what you need.
3. **UFW must be enabled to do anything.** Rules added while disabled are saved but not applied.
4. **Rules persist automatically.** No permanent/runtime distinction.

Everything else is just commands you can look up. These four concepts are what actually matter.

## Cheat Sheet

```bash
# Show state
ufw status
ufw status verbose
ufw status numbered

# Allow / deny (TCP/UDP specified or defaults to both)
ufw allow <port>
ufw allow <port>/<proto>
ufw allow <service>
ufw allow from <ip-or-cidr> to any port <port>
ufw allow in on <interface>
ufw deny <port>
ufw limit ssh                       # rate-limit against brute-force

# Remove
ufw delete allow <port>             # by specification
ufw delete <number>                 # by number from `status numbered`

# Control
ufw enable
ufw disable
ufw reload
ufw reset                           # wipe all rules

# Defaults
ufw default deny incoming
ufw default allow outgoing

# Logging
ufw logging on
ufw logging medium
tail -f /var/log/ufw.log
```

That's the whole thing. UFW is deliberately simple — for most use cases, five or six rules cover everything you need.
