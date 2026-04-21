"""
Create a CML 2.x lab with 3 routers in a triangle topology, all running OSPF area 0.

Requirements:
    pip install virl2-client

Credentials — set these in the environment or edit the constants below:
    CML_URL       e.g. https://cml.example.com
    CML_USERNAME
    CML_PASSWORD

Topology:

        R1 (1.1.1.1)
        /          \\
 10.0.12.0/30   10.0.13.0/30
      /              \\
   R2 (2.2.2.2) --- R3 (3.3.3.3)
          10.0.23.0/30

All links in OSPF area 0. Loopback0 on each router advertised into OSPF.
"""

import os
from virl2_client import ClientLibrary

# ---------- Connection settings ----------
CML_URL      = os.getenv("CML_URL",      "https://cml.example.com")
CML_USERNAME = os.getenv("CML_USERNAME", "admin")
CML_PASSWORD = os.getenv("CML_PASSWORD", "changeme")

# ---------- Router day-0 configs ----------
# Interface map per router:
#   Gi0/0 — unused (mgmt/console)
#   Gi0/1 — first peer
#   Gi0/2 — second peer

R1_CONFIG = """\
hostname R1
!
interface Loopback0
 ip address 1.1.1.1 255.255.255.255
!
interface GigabitEthernet0/1
 description to R2
 ip address 10.0.12.1 255.255.255.252
 no shutdown
!
interface GigabitEthernet0/2
 description to R3
 ip address 10.0.13.1 255.255.255.252
 no shutdown
!
router ospf 1
 router-id 1.1.1.1
 network 1.1.1.1 0.0.0.0 area 0
 network 10.0.12.0 0.0.0.3 area 0
 network 10.0.13.0 0.0.0.3 area 0
!
end
"""

R2_CONFIG = """\
hostname R2
!
interface Loopback0
 ip address 2.2.2.2 255.255.255.255
!
interface GigabitEthernet0/1
 description to R1
 ip address 10.0.12.2 255.255.255.252
 no shutdown
!
interface GigabitEthernet0/2
 description to R3
 ip address 10.0.23.1 255.255.255.252
 no shutdown
!
router ospf 1
 router-id 2.2.2.2
 network 2.2.2.2 0.0.0.0 area 0
 network 10.0.12.0 0.0.0.3 area 0
 network 10.0.23.0 0.0.0.3 area 0
!
end
"""

R3_CONFIG = """\
hostname R3
!
interface Loopback0
 ip address 3.3.3.3 255.255.255.255
!
interface GigabitEthernet0/1
 description to R2
 ip address 10.0.23.2 255.255.255.252
 no shutdown
!
interface GigabitEthernet0/2
 description to R1
 ip address 10.0.13.2 255.255.255.252
 no shutdown
!
router ospf 1
 router-id 3.3.3.3
 network 3.3.3.3 0.0.0.0 area 0
 network 10.0.23.0 0.0.0.3 area 0
 network 10.0.13.0 0.0.0.3 area 0
!
end
"""


def ensure_interfaces(node, count: int):
    """Make sure the node has at least `count` physical interfaces (slots 0..count-1)."""
    while len(node.physical_interfaces) < count:
        node.create_interface()


def main():
    # Connect
    client = ClientLibrary(
        CML_URL,
        CML_USERNAME,
        CML_PASSWORD,
        ssl_verify=False,   # set True in production
    )
    client.is_system_ready(wait=True)

    # Create lab
    lab = client.create_lab(title="3-Router OSPF Triangle")
    print(f"Created lab '{lab.title}' (id={lab.id})")

    # Create nodes — "iosv" is the small Cisco IOSv router (good enough for OSPF)
    r1 = lab.create_node("R1", "iosv", x=-200, y=-100)
    r2 = lab.create_node("R2", "iosv", x= 200, y=-100)
    r3 = lab.create_node("R3", "iosv", x=   0, y= 150)

    # Push day-0 configs
    r1.configuration = R1_CONFIG
    r2.configuration = R2_CONFIG
    r3.configuration = R3_CONFIG

    # Make sure each router has Gi0/0, Gi0/1, Gi0/2 (slots 0,1,2)
    for node in (r1, r2, r3):
        ensure_interfaces(node, 3)

    # Wire the triangle. Slot index matches Gi0/N.
    #   R1 Gi0/1  <-> R2 Gi0/1   (10.0.12.0/30)
    #   R2 Gi0/2  <-> R3 Gi0/1   (10.0.23.0/30)
    #   R1 Gi0/2  <-> R3 Gi0/2   (10.0.13.0/30)
    lab.create_link(r1.physical_interfaces[1], r2.physical_interfaces[1])
    lab.create_link(r2.physical_interfaces[2], r3.physical_interfaces[1])
    lab.create_link(r1.physical_interfaces[2], r3.physical_interfaces[2])

    print("Nodes and links created. Starting lab...")
    lab.start()
    print("Lab is running.")
    print()
    print("Verify once routers boot (~1-2 min):")
    print("  R1# show ip ospf neighbor")
    print("  R1# show ip route ospf")
    print("  R1# ping 3.3.3.3 source 1.1.1.1")


if __name__ == "__main__":
    main()
