#!/usr/bin/env python3
"""
cml_bgp_lab.py — Build and boot a BGP practice lab on CML.

Topology:
                       iBGP
        AS 65001         |          AS 65003
       ┌──────┐  eBGP  ┌─┴────┐  eBGP  ┌──────┐
       │  R1  │────────│  R2  │────────│  R3  │
       └──────┘        └───┬──┘        └──────┘
                           │
                       ┌───┴──┐
                       │  R4  │   (AS 65002, iBGP with R2)
                       └──────┘

Addressing:
    Loopbacks (advertised in BGP):
        R1 Lo0 = 1.1.1.1/32
        R2 Lo0 = 2.2.2.2/32
        R3 Lo0 = 3.3.3.3/32
        R4 Lo0 = 4.4.4.4/32

    Point-to-point /30s:
        R1 <-> R2 : 10.0.12.0/30  (R1=.1, R2=.2)
        R2 <-> R3 : 10.0.23.0/30  (R2=.2, R3=.3)
        R2 <-> R4 : 10.0.24.0/30  (R2=.2, R4=.4)

Credentials baked into each router:
    username cisco / password cisco (enable: cisco)

Requirements:
    pip install virl2_client
"""

import getpass
import sys
import urllib3

try:
    from virl2_client import ClientLibrary
except ImportError:
    sys.exit("Missing dependency: pip install virl2_client")


# -------- topology definition -------------------------------------------------

ROUTERS = {
    "R1": {"asn": 65001, "loopback": "1.1.1.1", "xy": (100, 200)},
    "R2": {"asn": 65002, "loopback": "2.2.2.2", "xy": (300, 200)},
    "R3": {"asn": 65003, "loopback": "3.3.3.3", "xy": (500, 200)},
    "R4": {"asn": 65002, "loopback": "4.4.4.4", "xy": (300, 400)},
}

# (node_a, node_b, /30 base, a_host, b_host)
LINKS = [
    ("R1", "R2", "10.0.12", 1, 2),
    ("R2", "R3", "10.0.23", 2, 3),
    ("R2", "R4", "10.0.24", 2, 4),
]


# -------- helpers -------------------------------------------------------------

def prompt(label, default=None, secret=False):
    if secret:
        return getpass.getpass(f"{label}: ")
    suffix = f" [{default}]" if default is not None else ""
    value = input(f"{label}{suffix}: ").strip()
    return value or default


def build_ios_config(hostname, asn, loopback, interfaces, neighbors):
    """
    Assemble an IOSv startup-config.

    interfaces:  list of dicts  {"name", "ip", "mask", "desc"}
    neighbors:   list of dicts  {"ip", "asn", "desc"}
    """
    lines = [
        "!",
        "service timestamps debug datetime msec",
        "service timestamps log datetime msec",
        "no service password-encryption",
        "!",
        f"hostname {hostname}",
        "!",
        "no ip domain lookup",
        "ip cef",
        "no ipv6 cef",
        "!",
        "username cisco privilege 15 secret cisco",
        "enable secret cisco",
        "!",
        "interface Loopback0",
        " description BGP router-id / advertised prefix",
        f" ip address {loopback} 255.255.255.255",
        "!",
    ]

    for i in interfaces:
        lines += [
            f"interface {i['name']}",
            f" description {i['desc']}",
            f" ip address {i['ip']} {i['mask']}",
            " no shutdown",
            "!",
        ]

    lines += [
        f"router bgp {asn}",
        f" bgp router-id {loopback}",
        " bgp log-neighbor-changes",
        " no synchronization",
        " no auto-summary",
        f" network {loopback} mask 255.255.255.255",
    ]
    for n in neighbors:
        lines.append(f" neighbor {n['ip']} remote-as {n['asn']}")
        lines.append(f" neighbor {n['ip']} description {n['desc']}")
        if n["asn"] == asn:
            # iBGP peer -> reflect/self next-hop for loopback reachability.
            lines.append(f" neighbor {n['ip']} next-hop-self")
    lines.append("!")

    lines += [
        "ip forward-protocol nd",
        "!",
        "line con 0",
        " logging synchronous",
        " exec-timeout 0 0",
        "line vty 0 4",
        " login local",
        " transport input telnet ssh",
        "!",
        "end",
    ]
    return "\n".join(lines)


# -------- main ----------------------------------------------------------------

def main():
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    print("=" * 55)
    print("  CML BGP Practice Lab Builder")
    print("=" * 55)

    host = prompt("CML host or IP")
    if not host:
        sys.exit("Host is required.")
    if not host.startswith(("http://", "https://")):
        host = f"https://{host}"
    username = prompt("Username", default="admin")
    password = prompt("Password", secret=True)
    if not password:
        sys.exit("Password is required.")
    lab_name = prompt("Lab name", default="BGP-Practice")

    # --- connect ---
    print(f"\n[+] Connecting to {host} ...")
    try:
        client = ClientLibrary(
            host, username=username, password=password, ssl_verify=False
        )
        client.is_system_ready(wait=True)
    except Exception as exc:
        sys.exit(f"[!] Connection failed: {exc}")
    print("[+] Connected.")

    # --- create lab and nodes ---
    print(f"\n[+] Creating lab '{lab_name}' ...")
    lab = client.create_lab(title=lab_name)
    lab.description = "BGP practice - 3 ASes, eBGP + iBGP (autogenerated)"

    print("[+] Creating routers ...")
    nodes = {}
    for label, meta in ROUTERS.items():
        x, y = meta["xy"]
        nodes[label] = lab.create_node(
            label=label, node_definition="iosv", x=x, y=y
        )
        print(f"    + {label}  AS{meta['asn']}  Lo0={meta['loopback']}")

    # --- create links and remember endpoints ---
    print("[+] Wiring links ...")
    # endpoints_by_node[node_label] = [{iface, ip, peer_label, peer_ip}, ...]
    endpoints_by_node = {label: [] for label in ROUTERS}

    for a_label, b_label, base, a_host, b_host in LINKS:
        a, b = nodes[a_label], nodes[b_label]
        ia = a.next_available_interface() or a.create_interface()
        ib = b.next_available_interface() or b.create_interface()
        lab.create_link(ia, ib)

        a_ip = f"{base}.{a_host}"
        b_ip = f"{base}.{b_host}"
        endpoints_by_node[a_label].append(
            {"iface": ia.label, "ip": a_ip, "peer": b_label, "peer_ip": b_ip}
        )
        endpoints_by_node[b_label].append(
            {"iface": ib.label, "ip": b_ip, "peer": a_label, "peer_ip": a_ip}
        )
        print(f"    {a_label}({ia.label}, {a_ip}) <-> {b_label}({ib.label}, {b_ip})")

    # --- push day-0 configs ---
    print("[+] Generating and pushing configs ...")
    for label, node in nodes.items():
        my_asn = ROUTERS[label]["asn"]
        interfaces = [
            {
                "name": ep["iface"],
                "ip": ep["ip"],
                "mask": "255.255.255.252",
                "desc": f"to-{ep['peer']}",
            }
            for ep in endpoints_by_node[label]
        ]
        neighbors = [
            {
                "ip": ep["peer_ip"],
                "asn": ROUTERS[ep["peer"]]["asn"],
                "desc": f"to-{ep['peer']}-AS{ROUTERS[ep['peer']]['asn']}",
            }
            for ep in endpoints_by_node[label]
        ]
        node.config = build_ios_config(
            hostname=label,
            asn=my_asn,
            loopback=ROUTERS[label]["loopback"],
            interfaces=interfaces,
            neighbors=neighbors,
        )
        print(f"    + config applied to {label}")

    # --- boot ---
    print("\n[+] Starting lab (IOSv first boot takes a few minutes) ...")
    try:
        lab.start(wait=True)
    except Exception as exc:
        sys.exit(f"[!] Start failed: {exc}")

    # --- summary ---
    print("\n" + "=" * 55)
    print("  Lab Ready")
    print("=" * 55)
    print(f"Title:   {lab.title}")
    print(f"Lab ID:  {lab.id}")
    print(f"State:   {lab.state()}")
    print("\nConsole login on any router:")
    print("    username: cisco")
    print("    password: cisco")
    print("    enable:   cisco")
    print("\nFirst commands to try (wait ~60s after start for BGP to converge):")
    print("    R2# show ip bgp summary")
    print("    R2# show ip bgp")
    print("    R1# show ip route bgp        (expect 2/3/4.*.*.* via R2)")
    print("    R3# show ip bgp              (expect 1.1.1.1 and 4.4.4.4 via R2)")
    print("    R4# show ip bgp              (learns 1.1.1.1/3.3.3.3 from R2 iBGP)")
    print("\nThings to try next:")
    print("  - Filter 4.4.4.4/32 from being advertised out of AS 65002 (prefix-list + route-map).")
    print("  - Set LOCAL_PREF on R2 for prefixes learned from R1 vs R3.")
    print("  - Prepend AS_PATH on R3 to steer R1 traffic via R2->R3 vs another path.")
    print("  - Add a second eBGP link between R1 and R3 (new /30) and observe path selection.")

    ui_base = host.rstrip("/")
    print(f"\nOpen lab: {ui_base}/lab/{lab.id}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\nAborted.")
