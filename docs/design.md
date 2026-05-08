# Design — Hybrid AWS Cloud WAN ↔ On-Prem EVPN/VXLAN Fabric

## 1. Topology

Two domains interconnected over IPsec:

- **Cloud domain**: AWS Cloud WAN core network spanning two regions (us-east-1, us-west-2). Two segments — `prod` (in us-east-1) and `dev` (in us-west-2) — with a sharing rule allowing bidirectional reachability between them. Each segment hosts one VPC and one test EC2.
- **On-prem domain**: Arista cEOS-lab containerlab fabric. Two spines (AS 65000), two leaves (AS 65101, 65102), eBGP underlay over /31 p2p links, eBGP-EVPN overlay across the same neighborships, symmetric IRB enabled, two tenants (TENANT-A: VLAN 100 / VNI 10100 / L3VNI 50000; TENANT-B: VLAN 200 / VNI 10200 / L3VNI 50001), anycast gateway `192.168.100.1/24` on both leaves for TENANT-A and `192.168.200.1/24` on both leaves for TENANT-B.
- **Interconnect**: AWS Site-to-Site VPN attached to the `prod` segment, IPsec terminates inside the on-prem fabric on a Linux container (`cpe-east`) attached to leaf1 as a TENANT-A access port. The customer-side strongswan initiates the tunnel; AWS responds; no inbound port-forward is required at the customer edge.

```
   [EC2-East]──VPC-East──Cloud WAN──S2S VPN──┐
                  prod      prod              │
                                              ▼
                                          [cpe-east]──leaf1.Eth4
                                                       │
                                                  spine1, spine2
                                                       │
                                                       ▼
                                                       leaf2 / h2
```

## 2. AWS-side resources

### 2.1 Cloud WAN core network

- Global Network: `aws_networkmanager_global_network.this` (managed in us-west-2 home region).
- Core Network: `aws_networkmanager_core_network.this`. Created with `create_base_policy = true` and `base_policy_regions = [us-east-1, us-west-2]` to bootstrap an AVAILABLE state before the real policy attaches.
- Policy: declarative JSON in `cloudwan.tf:locals.core_network_policy`. Three top-level blocks consumed by the attachment-policy resource:
  - `core-network-configuration` — `asn-ranges = ["64512-64529"]`, `edge-locations` covering both regions.
  - `segments` — `prod` and `dev`, each with `require-attachment-acceptance = false`.
  - `segment-actions` — one rule: `action = share, segment = prod, share-with = ["dev"]`. Removes the default segment-isolation between prod and dev.
  - `attachment-policies` — one rule (`rule-number = 100`) with `condition: tag-exists key=Segment` and `action: association-method=tag, tag-value-of-key=Segment`. Auto-associates any new attachment carrying a `Segment` tag to the segment named in the tag value.
- Edge ASNs auto-assigned by Cloud WAN: **us-east-1 = 64512, us-west-2 = 64513**. (Confirmed via `aws networkmanager get-core-network-change-set --policy-version-id 1`.) These are the BGP ASNs of the Cloud WAN edges — different from the customer-side AS 65000.

### 2.2 VPC attachments (data plane)

- `aws_networkmanager_vpc_attachment.east` — VPC-East (10.10.0.0/16) in us-east-1, tagged `Segment = prod`, attaches a public subnet `10.10.1.0/24`.
- `aws_networkmanager_vpc_attachment.west` — VPC-West (10.20.0.0/16) in us-west-2, tagged `Segment = dev`, attaches public subnet `10.20.1.0/24`.
- Each VPC has an Internet Gateway, default route to it, and a per-subnet route table with an explicit route to the remote VPC CIDR with `core_network_arn` as the next hop.

### 2.3 Test compute

- `aws_instance.east`: t3.nano, AL2023, in `aws_subnet.east`, public IPv4 enabled, security group allows inbound SSH from operator and ICMP from RFC1918 source space.
- `aws_instance.west`: same shape, in `aws_subnet.west`.

### 2.4 Site-to-Site VPN (interconnect to on-prem)

- `aws_customer_gateway.cpe_east` — type `ipsec.1`, BGP ASN 65000, IP `<laptop-WAN-public-IP>`, tagged `Segment = prod`.
- `aws_vpn_connection.cpe_east` — type `ipsec.1`, customer gateway above, `static_routes_only = true`, `outside_ip_address_type = "PublicIpv4"`, tagged `Segment = prod`.
- `aws_vpn_connection_route` — destination `192.168.100.0/24` propagated into the VPN's static-route table (advertises the on-prem TENANT-A overlay subnet to AWS).
- `aws_networkmanager_site_to_site_vpn_attachment.cpe_east` — attaches the VPN to the Cloud WAN core network. Tag `Segment = prod` causes the attachment-policy rule to bind it to the `prod` segment. Explicit `depends_on = [aws_networkmanager_core_network_policy_attachment.this]` to enforce ordering.
- AWS provisions two IPsec tunnels per VPN connection (active/passive) with separate inside CIDRs, public outside addresses, and pre-shared keys. Tunnel parameters surface as Terraform outputs (PSKs marked `sensitive`).

## 3. On-prem (containerlab) resources

### 3.1 Fabric nodes

| Node | Kind | Image | Role | Mgmt IP | Loopback0 | Loopback1 (VTEP) | ASN |
|---|---|---|---|---|---|---|---|
| spine1 | arista_ceos | ceos:4.36.0.1F | spine | 172.31.10.11 | 10.0.0.11 | — | 65000 |
| spine2 | arista_ceos | ceos:4.36.0.1F | spine | 172.31.10.12 | 10.0.0.12 | — | 65000 |
| leaf1  | arista_ceos | ceos:4.36.0.1F | leaf  | 172.31.10.21 | 10.0.0.21 | 10.1.1.21 | 65101 |
| leaf2  | arista_ceos | ceos:4.36.0.1F | leaf  | 172.31.10.22 | 10.0.0.22 | 10.1.1.22 | 65102 |
| h1     | linux       | alpine:3.20    | host  | 172.31.10.101 | — | — | — |
| h2     | linux       | alpine:3.20    | host  | 172.31.10.102 | — | — | — |
| cpe-east | linux     | alpine:3.20    | CPE / VPN concentrator | 172.31.10.103 | — | — | — |

### 3.2 Underlay (eBGP IPv4 unicast over /31 p2p)

Per-leaf neighbor pairs:

```
spine1 (65000)  --10.10.11.0/31--  leaf1 (65101)
spine1 (65000)  --10.10.21.0/31--  leaf2 (65102)
spine2 (65000)  --10.10.12.0/31--  leaf1 (65101)
spine2 (65000)  --10.10.22.0/31--  leaf2 (65102)
```

`maximum-paths 4 ecmp 4` on every speaker. Loopback0 (router-id) advertised via `network`, Loopback1 (VTEP source) advertised via `network`. MTU 9214 on every p2p interface to support VXLAN 50-byte overhead plus tenant jumbo frames.

### 3.3 Overlay (eBGP-EVPN over the same neighborships)

Same TCP sessions, additional address-family `l2vpn evpn` activated on the SPINE peer-group on each leaf and on the LEAF peer-group on each spine. Spines transit RT-2/RT-3/RT-5 routes between the two leaves. Send-community-extended set on the peer-groups.

> **Service-interface mode**: this fabric uses **per-VLAN MAC-VRF** (RFC 7432 mode 1 — one EVI per VLAN). One `vlan <id>` stanza per VLAN under `router bgp`. Appropriate at this lab's scale (2 tenants, 2 VLANs total). Mode 3 (VLAN-aware-bundle) trades per-VLAN RT control for state economy and only pays off above ~50 VLANs; deliberately not used here.

Per-leaf MAC-VRF (per-VLAN) blocks:

```
router bgp 65101
   vlan 100              <-- L2 EVI for VLAN 100
      rd 10.0.0.21:10100
      route-target both 10100:10100
      redistribute learned
   vlan 200
      rd 10.0.0.21:10200
      route-target both 10200:10200
      redistribute learned
```

Per-leaf IP-VRF blocks (under `router bgp 65101 vrf TENANT-A`): `rd 10.0.0.21:50000`, `route-target import/export evpn 50000:50000`, `redistribute connected`. Same shape for TENANT-B with `:50001` RTs.

### 3.4 VXLAN dataplane

```
interface Vxlan1
   vxlan source-interface Loopback1
   vxlan udp-port 4789
   vxlan vlan 100 vni 10100
   vxlan vlan 200 vni 10200
   vxlan vrf TENANT-A vni 50000
   vxlan vrf TENANT-B vni 50001
```

### 3.5 Tenants

- TENANT-A: VRF, SVI Vlan100 with `ip address virtual 192.168.100.1/24` on both leaves, anycast MAC `00:1c:73:00:00:01`. Members: h1 (192.168.100.101 on leaf1.Eth3), cpe-east (192.168.100.50 on leaf1.Eth4).
- TENANT-B: VRF, SVI Vlan200 with `ip address virtual 192.168.200.1/24` on both leaves. Member: h2 (192.168.200.102 on leaf2.Eth3).

### 3.6 cpe-east (CPE / VPN concentrator)

Linux container (alpine:3.20). Three interfaces:

- `eth0` (172.31.10.103) — clab mgmt bridge → docker0 → host wlp3s0 → home router → public internet (IPsec underlay path)
- `eth1` (192.168.100.50/24) — leaf1.Eth4 access VLAN 100 (TENANT-A access)
- `eth2` (192.168.200.50/24) — leaf1.Eth5 access VLAN 200 (TENANT-B access). cpe-east aggregates both tenants at the CPE — pattern-equivalent to a real branch-site SD-WAN appliance terminating multiple VRFs.

Software: strongswan 5.9.13 (in **swanctl/vici** mode, not legacy stroke), FRR 10.0 (zebra + bgpd), iproute2, iptables, tcpdump.

#### Tunnels (route-based via xfrm interfaces)

Two IPsec child SAs to AWS, IKEv2/AES-128/SHA-1/MODP-1024 (AWS default proposal). Both with `mark_in` / `mark_out` set on the strongswan conn so the kernel marks packets traversing the SA. The marks bind to **xfrm interfaces** (modern Linux replacement for legacy VTI):

```
ip link add xfrm0 type xfrm dev eth0 if_id 0x64    # tunnel 1, AWS endpoint 34.214.170.247
ip link add xfrm1 type xfrm dev eth0 if_id 0xc8    # tunnel 2, AWS endpoint 100.21.221.32
ip addr add 169.254.50.106/30  dev xfrm0           # /30 customer side, tunnel 1
ip addr add 169.254.243.142/30 dev xfrm1           # /30 customer side, tunnel 2
```

**xfrm interfaces vs legacy VTI**: xfrm interfaces use the kernel's modern netdev abstraction with `if_id` matching against XFRM SA marks. Legacy VTI used `key` + iptables-mangle MARK rules; the mark propagation path through the netfilter pipeline is fragile under newer kernels. xfrm interfaces are the canonical 2024+ approach for BGP-over-IPsec on Linux (kernel ≥4.19).

#### BGP (FRR)

```
router bgp 65000                              # customer ASN
 bgp router-id 192.168.100.50
 neighbor AWS-VPN peer-group
 neighbor AWS-VPN remote-as 64513             # AWS-side: VPN-attachment-local edge ASN
 neighbor 169.254.50.105  peer-group AWS-VPN  # tunnel 1 AWS BGP peer
 neighbor 169.254.50.105  update-source 169.254.50.106    # source from xfrm0 inside addr
 neighbor 169.254.243.141 peer-group AWS-VPN  # tunnel 2 AWS BGP peer
 neighbor 169.254.243.141 update-source 169.254.243.142   # source from xfrm1 inside addr
 address-family ipv4 unicast
  network 192.168.100.0/24                    # advertise TENANT-A overlay
  network 192.168.200.0/24                    # advertise TENANT-B overlay
  neighbor AWS-VPN activate
```

Both tenant subnets advertised first-class — no SNAT, no shortcuts. AWS learns each as a distinct prefix and propagates into the Cloud WAN prod segment routing table. cpe-east receives 10.10.0.0/16 and 10.20.0.0/16 from AWS, installs into kernel RIB, redistributes via static into TENANT-A / TENANT-B VRFs on the leaves.

**The AWS-side BGP ASN gotcha**: AWS uses **the Cloud WAN edge ASN where the VPN attachment is provisioned** (us-west-2 = 64513), not where the destination VPCs live (us-east-1 = 64512). Initial assumption of 64512 prevented the BGP session from establishing — diagnosed by checking AWS's `get-core-network-change-set` and reading the `EdgeLocations`/`Asn` mapping per-edge. Documented in postmortem `02-bgp-migration.md`.

#### Active/active redundancy

Both tunnels run BGP independently. AWS uses ECMP across both tunnels for inbound traffic. cpe-east's outbound path picks the lower-MED route or first-installed (effectively round-robin under typical AWS BGP advertisement). Loss of one tunnel triggers BGP hold-timer expiry (default 30s, configurable) → traffic shifts to the other.

## 4. Address plan

| Scope | CIDR / Address |
|---|---|
| AWS VPC-East | 10.10.0.0/16 (subnet 10.10.1.0/24) |
| AWS VPC-West | 10.20.0.0/16 (subnet 10.20.1.0/24) |
| Underlay p2p (spine ↔ leaf) | 10.10.{11,12,21,22}.0/31 |
| Loopback0 (router-id) | 10.0.0.{11,12,21,22}/32 |
| Loopback1 (VTEP source) | 10.1.1.{21,22}/32 |
| TENANT-A overlay | 192.168.100.0/24 |
| TENANT-B overlay | 192.168.200.0/24 |
| Containerlab mgmt | 172.31.10.0/24 |
| AWS S2S VPN inside (tunnel1) | 169.254.50.104/30 — AWS .105, customer .106 (xfrm0) |
| AWS S2S VPN inside (tunnel2) | 169.254.243.140/30 — AWS .141, customer .142 (xfrm1) |
| BGP — customer ASN | 65000 (cpe-east FRR) |
| BGP — AWS-side ASN | 64513 (us-west-2 Cloud WAN edge — local to VPN attachment) |

## 5. Forwarding paths

### 5.1 EC2-East → h1 (cross-domain, intra-tenant) — *validated*

```
EC2-East (10.10.1.x/24, VPC-East)
  → VPC-East route table: dst 192.168.100.0/24 → core_network_arn
  → Cloud WAN core network (prod segment, us-east-1 edge)
  → cross-region forwarding inside the segment to us-west-2 edge
  → S2S VPN attachment (us-west-2 edge, prod segment)
  → BGP-installed route → IPsec tunnel-2 (xfrm1 on cpe-east)
  → kernel decrypt → forward via eth1 (leaf1.Eth4, VLAN 100, TENANT-A)
  → leaf1 EVPN: dst 192.168.100.101 known via local RT-2 (h1 on leaf1.Eth3)
  → h1
```

**Return path**: h1 → leaf1 SVI Vlan100 (anycast 192.168.100.1) → leaf1 RIB lookup in TENANT-A VRF (10.10.0.0/16 either as static `via 192.168.100.50` or BGP-redistributed from cpe-east) → ARP cpe-east → forward via Eth4 → cpe-east kernel routes via xfrm1 → IPsec encrypt → eth0 → docker NAT → laptop NAT → home-router NAT → ESP/4500 → AWS Tunnel-2 endpoint (100.21.221.32) → Cloud WAN prod segment → VPC-East attachment → EC2-East.

**Empirical**: 0% loss, 144-341 ms RTT (5/5 packets) — the spread reflects IPsec SA freshness + BGP route convergence on cold paths.

### 5.1b EC2-East → h2 (cross-domain, cross-tenant)

Same path through the Cloud WAN + VPN; cpe-east lands the decrypted packet on **eth2** (leaf1.Eth5, VLAN 200, TENANT-B) based on its kernel routing table (192.168.200.0/24 directly connected). leaf2's SVI Vlan200 anycast receives the L2 frame after EVPN cross-leaf MAC propagation, forwards to h2 via Eth3.

**Empirical**: 0% loss, 153-415 ms RTT (5/5 packets).

The fact that **one CPE serves both tenants without NAT** is the multi-tenant CPE pattern. cpe-east advertises both prefixes (192.168.100.0/24 and 192.168.200.0/24) to AWS via BGP from FRR; AWS installs both into the prod segment routing table. No SNAT, no policy-based routing — just two L3 interfaces and proper BGP advertisement.

### 5.2 EC2-East → EC2-West (intra-cloud, inter-segment)

```
EC2-East → VPC-East RT: dst 10.20.0.0/16 via core_network_arn
  → Cloud WAN core network
  → segment-actions allows prod → dev share
  → VPC-West attachment in dev segment
  → EC2-West
```

No on-prem or VPN involvement. RTT measured at ~56 ms.

### 5.3 h1 ↔ h2 (intra-fabric, inter-tenant) — currently isolated

h1 (TENANT-A) cannot reach h2 (TENANT-B). VRFs do not import each other's L3 RTs (50000 vs 50001). Cross-VRF route leaking would require explicit `route-target import evpn 50001:50001` under `vrf TENANT-A` on each leaf (and the corresponding reverse).

## 6. Failure boundaries

| Boundary | What stops if it fails |
|---|---|
| Cloud WAN core network | All cross-region and cross-segment cloud forwarding |
| Segment policy (`prod ⇆ dev` share rule) | Inter-segment forwarding (each segment still works internally) |
| S2S VPN attachment | Cloud-to-on-prem traffic (cloud-internal still works) |
| IPsec tunnel-2 only | Cloud-to-on-prem traffic; tunnel-1 BGP comes up after a brief ECMP shift, ~30s BGP-hold convergence |
| IPsec tunnel-1 only | Same — opposite direction; tunnel-2 takes over |
| Both IPsec tunnels | All cloud-to-on-prem traffic stops; recovery requires IKE re-establishment |
| cpe-east container | All cloud-to-on-prem traffic; SPOF at customer edge by design at lab scale. **Production**: redundant CPE pair with BGP / VRRP / equal-cost ECMP via the SD-WAN device's HA model. |
| leaf1 | h1 + cpe-east reachability (cpe-east is single-homed to leaf1.Eth4 + leaf1.Eth5). h2's path through leaf2 unaffected for fabric-internal traffic, but cloud reach impacted because cpe-east is leaf1-attached. |
| spine1 OR spine2 (not both) | No data-plane impact; ECMP collapses to remaining spine; BFD detection ~900 ms |
| h1 ARP age-out | RT-2 withdraws ~300 s after last traffic; reachability restored on next ARP |

## 7. Tools and versions

| Component | Version |
|---|---|
| Terraform | 1.15.2 |
| AWS provider | 5.70.x |
| AWS CLI | 2.34.45 |
| Containerlab | (lab-runtime version on host) |
| Arista cEOS-lab | 4.36.0.1F (engineering build) |
| alpine container image | 3.20 |
| strongSwan | 5.9.13 (vici/swanctl mode, not legacy stroke) |
| FRR | 10.0-r2 (zebra + bgpd; vtysh CLI) |
| Cloud WAN policy schema | 2021.12 |
| BGP — IKE proposal | AES-128-CBC / SHA-1 / MODP-1024 (AWS default) |

## 8. State and lifecycle

Terraform state local-only at `~/aws-cloudwan/terraform/terraform.tfstate` (not committed). `~/.aws/credentials` referenced via default profile. Containerlab state at `~/train/topology/clab-evpn-fabric/`. cEOS startup-config sourced from `~/train/topology/configs/<node>.cfg` (committed). On-prem state survives lab destroy/redeploy via the startup-config files. AWS state survives `terraform apply`/`destroy` cycles via the state file; full destroy returns the AWS account to baseline (no Cloud WAN attachments, no VPN, no Cloud WAN core network, $0 idle cost).
