# IPsec extension — Cloud WAN `prod` segment to on-prem EVPN fabric (static-route phase)

## 1. Goal

Extend the Phase 1 Cloud WAN core (postmortem `00`) with an AWS Site-to-Site VPN that terminates on a Linux CPE inside an on-prem containerlab EVPN fabric, then prove end-to-end reachability with a single ping from a tenant host (`h1`, behind the EVPN fabric) to EC2-East (in VPC-East via Cloud WAN).

The ping is the artifact; the boundary crossings are the engineering. A Cloud WAN segment, a managed VPN, a public-internet IPsec tunnel, NAT traversal off a residential WAN, a tenant VLAN, and an EVPN type-2 lookup in TENANT-A all end up on the same packet path.

## 2. Architecture summary

See `../diagrams/topology.mmd`.

- AWS `prod` segment in us-east-1 contains VPC-East (`10.10.0.0/16`) and a new VPN attachment (us-west-2 edge — the VPN attachment's edge differs from the VPC's edge; Cloud WAN forwards inside the segment between edges automatically).
- VPN attachment tagged `Segment = prod`, picked up by the existing tag-based attachment-policy — no hardcoded segment ARN.
- Customer side is `cpe-east`, an alpine container running strongSwan. Inside TENANT-A on VLAN 100 (`192.168.100.50/24`), uplinked to `leaf1.Eth4` as an access port, with a separate uplink to the clab management bridge for outbound internet to the AWS VPN endpoints.
- `cpe-east` is the IPsec **initiator** (`auto = start`) — the laptop's home router NATs outbound only; AWS happily terminates a tunnel to whatever NAT'd source it sees from `24.42.204.221`.

## 3. AWS side — Terraform additions

`terraform/vpn.tf`:

- `aws_customer_gateway.cpe_east` — `ip_address = var.customer_public_ip`, `bgp_asn = 65000` (placeholder, since static-route mode ignores BGP).
- `aws_vpn_connection.cpe_east` — `static_routes_only = true`, two tunnels, AWS-generated PSK + inside CIDRs.
- `aws_networkmanager_site_to_site_vpn_attachment.cpe_east` — references the VPN connection, tagged `Segment = prod`.
- `aws_vpn_connection_route.cpe_east_tenant_a` — destination `192.168.100.0/24` propagated into the VPN's static-route table (so AWS knows to send VPC-East return traffic for that prefix into the tunnel).

`terraform/outputs.tf` exposes `vpn_xml_config` (sensitive: PSKs + tunnel parameters). The operator pulls this with `terraform output -json` and feeds the data into `cpe-east`'s strongswan config; the secret material never lands in git.

## 4. Customer side — strongSwan ipsec.conf (legacy stroke / policy-based)

```
conn %default
    auto=start
    keyexchange=ikev2
    type=tunnel
    leftauth=psk
    rightauth=psk
    leftid=24.42.204.221
    left=%defaultroute
    leftsubnet=192.168.100.0/24
    rightsubnet=10.10.0.0/16
    ike=aes256-sha256-modp2048
    esp=aes256-sha256-modp2048
    dpdaction=restart
    closeaction=restart

conn aws-tunnel-1
    right=<aws-t1-public-ip>
    rightid=<aws-t1-public-ip>

conn aws-tunnel-2
    right=<aws-t2-public-ip>
    rightid=<aws-t2-public-ip>
```

PSKs in `/etc/ipsec.secrets`, mode 0600, sourced from `terraform output`. NAT-T detected automatically; ESP rides over UDP/4500.

`net.ipv4.ip_forward = 1`. Static route on `leaf1` in TENANT-A VRF: `ip route vrf TENANT-A 10.10.0.0/16 192.168.100.50` so on-prem hosts find the AWS-side prefix via cpe-east.

## 5. Issues encountered (4)

### 5.1 — h1 had no route to 10.10.0.0/16

**Symptom**: `ping 10.10.1.103` from h1 returned silently; nothing in any tcpdump.

**Diagnosis**: alpine container's IP stack only had `192.168.100.0/24` directly connected and `default via 172.31.10.1` (clab mgmt bridge). The default route would have NAT'd the packet out to the public internet, but the destination 10.10.1.103 isn't reachable that way. Linux happily blackholed the packet without an ICMP unreachable.

**Fix**: `ip route add 10.10.0.0/16 via 192.168.100.1 dev eth1` on h1 — sends AWS-bound traffic to the leaf1 anycast SVI.

**Production lesson**: the host's routing table is part of the architecture. In a real deployment, the host gets the cloud-prefix route via DHCP option 121 or via the SVI's RA-style advertisement, not by hand.

### 5.2 — VPC-East subnet route table missing return route

**Symptom**: `ipsec statusall` showed encrypted bytes leaving cpe-east; `tcpdump` on EC2-East showed echo requests **arriving** and replies **leaving** — but no replies returned through the tunnel.

**Diagnosis**: VPC-East subnet RT didn't have an entry for `192.168.100.0/24`. The reply packet hit the IGW default route and got internet-NAT'd, never reaching the VPN attachment.

**Fix**: add a route in the subnet RT pointing `192.168.100.0/24` → `core_network_arn`. Cloud WAN then handles delivery to the VPN attachment.

**Production lesson**: VPC subnet route tables don't auto-populate from Cloud WAN segment routes. Each subnet that needs to reach a remote prefix needs an explicit route entry — same as TGW. Tag/role automation should handle this in IaC.

### 5.3 — Cloud WAN segment routing table missing the on-prem prefix

**Symptom**: VPC-East RT had the correct `192.168.100.0/24` → core_network_arn route, but Cloud WAN's prod segment routing table at the us-east-1 edge contained only `10.10.0.0/16` and `10.20.0.0/16` (the propagated VPC routes), no on-prem prefix.

**Diagnosis**: `aws_vpn_connection_route` populates the VPN connection's *own* routing context (used for Linux-side decisions if you query AWS) but **does NOT populate the Cloud WAN segment routing table**. Cloud WAN segment routing requires explicit policy.

Verified via:
```
aws networkmanager get-network-routes \
  --core-network-id <cn-id> \
  --route-table-identifier '{"CoreNetworkSegmentEdge":{...,"SegmentName":"prod","EdgeLocation":"us-east-1"}}'
```

**Fix**: add a `create-route` segment-action to the Cloud WAN policy doc:
```hcl
{
  action                    = "create-route"
  segment                   = "prod"
  "destination-cidr-blocks" = ["192.168.100.0/24"]
  destinations              = ["<vpn-attachment-id>"]
}
```

The VPN attachment ID has to be hardcoded (or computed at apply-time) because Terraform sees a dependency cycle if the policy references the attachment, which depends on the policy.

**Production lesson**: Cloud WAN policy is **the** routing fabric. Segment-actions like `create-route` and `share` are how prefixes get into edges. Don't expect AWS Cloud WAN attachments' own routes to propagate into segment routing automatically — you have to declare segment-level intent in the policy.

### 5.4 — strongSwan dual-tunnel XFRM template mismatch

**Symptom**: 252 bytes outbound encrypted on tunnel-2, 0 bytes inbound. AWS replies arriving at the cpe-east host kernel but `XfrmInTmplMismatch: 10` in `/proc/net/xfrm_stat`.

**Diagnosis**: strongSwan with two `conn` blocks pointing at the same `leftsubnet`/`rightsubnet` pair installs XFRM policy for **only one tunnel at a time** — whichever was last `up`. AWS's BGP-less VPN load-balances replies across both tunnels by default. Replies arriving on the "other" tunnel hit the IN policy with mismatched template (wrong remote endpoint), get dropped at XFRM.

Trace:
```
ip xfrm policy
src 10.10.0.0/16 dst 192.168.100.0/24
   dir fwd priority 379519
   tmpl src 184.32.21.137 dst 172.31.10.103   ← only tunnel-2 (184.x), not tunnel-1
```

**Fix**: `ipsec down aws-tunnel-1` to force AWS to stop using it (AWS observes IKE down and stops sending replies via that tunnel). The remaining tunnel-2 carries all traffic. Single-tunnel works for the demo.

**Production lesson**: legacy strongSwan policy-based mode does not support active/active dual-tunnel cleanly. The fix for true active/active is **either** route-based (xfrm interfaces with `mark_in/mark_out`) **or** convert to BGP-mode VPN. We did the latter in postmortem `02`.

## 6. Validation

```
$ docker exec clab-evpn-fabric-h1 ping -c 5 -W 4 10.10.1.103
PING 10.10.1.103 (10.10.1.103): 56 data bytes
64 bytes from 10.10.1.103: seq=1 ttl=123 time=341.424 ms
64 bytes from 10.10.1.103: seq=2 ttl=123 time=144.717 ms
64 bytes from 10.10.1.103: seq=3 ttl=123 time=146.629 ms
64 bytes from 10.10.1.103: seq=4 ttl=123 time=272.858 ms
--- 10.10.1.103 ping statistics ---
5 packets transmitted, 5 packets received, 0% packet loss
rtt min/avg/max = 144.717/210.565/341.424 ms
```

The first packet's RTT is consistently elevated — IPsec SA freshness + EVPN route warm-up + ARP resolution all cold the first time.

## 7. State at end of phase

- 1 IPsec tunnel ESTABLISHED (tunnel-2 only, tunnel-1 brought down for the dual-tunnel mismatch issue)
- Cloud WAN prod segment routes `192.168.100.0/24` to the VPN attachment via the explicit `create-route` policy entry
- Static route on leaf1 TENANT-A VRF: `10.10.0.0/16 → 192.168.100.50`
- One tenant (TENANT-A) connected to AWS

Phase 2 (BGP migration + multi-tenant) is documented in postmortem `02`.

## 8. Production lessons

1. **Three layers of routing must agree** for cloud↔on-prem to work: (a) host routing on the endpoint, (b) VPC subnet RT, (c) Cloud WAN segment policy. Any one missing produces silent blackholes. Validation at all three layers should be part of any IaC bring-up checklist.
2. **`aws_vpn_connection_route` is not enough** with Cloud WAN. The VPN's own route table doesn't propagate to segment routing — you need explicit `create-route` segment-actions or BGP-learned routes (Phase 2).
3. **Initiator-only at the branch** eliminates an entire class of NAT/firewall issues. Designing the CPE as the IKE initiator with `auto=start` + aggressive DPD is the production default for residential or CGNAT'd sites.
4. **Legacy policy-based IPsec doesn't do dual-tunnel cleanly.** Either accept single-tunnel + manual failover, or move to xfrm-interfaces + BGP. AWS expects active/active and BGP is the canonical answer. (See postmortem `02`.)
5. **Keep secrets out of git, but keep the plumbing in git.** Terraform's `sensitive = true` on PSK outputs + a docker exec stdin pattern keeps the PSK off disk on the host while letting the resource graph remain version-controlled. A "we'll add the VPN by hand" approach is CMDB drift waiting to happen.
