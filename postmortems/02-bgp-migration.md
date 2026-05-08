# BGP migration — static-route VPN → BGP-mode VPN with active/active xfrm interfaces

## 1. Goal

Convert the static-route VPN from postmortem `01` into a **BGP-based** VPN attachment. Outcomes wanted:

- Both AWS-side IPsec tunnels carry data simultaneously (active/active ECMP)
- AWS learns customer prefixes dynamically — no `aws_vpn_connection_route`
- Cloud WAN prod segment learns on-prem prefixes via BGP propagation, no `create-route` segment-actions for those prefixes
- Add a second tenant (TENANT-B / `192.168.200.0/24`) reachable from AWS over the same VPN attachment
- Remove the strongSwan dual-tunnel template-mismatch hack from postmortem `01`
- Convert to **xfrm interfaces** (modern Linux ≥4.19) instead of legacy VTI

## 2. AWS-side change

`terraform/vpn.tf`:

- `aws_vpn_connection.cpe_east` — flip `static_routes_only = true` → `false`. Trigger: VPN connection is destroy-replace (~6 min).
- Remove `aws_vpn_connection_route.cpe_east_tenant_a` — BGP advertises the prefix dynamically.
- Add outputs: `vpn_aws_tunnel{1,2}_vgw_inside_address`, `vpn_aws_tunnel{1,2}_cgw_inside_address`, `vpn_aws_tunnel{1,2}_bgp_asn` — needed for FRR config.

`terraform/cloudwan.tf` (separate decision): can also drop the `create-route` segment-action for `192.168.100.0/24` once BGP is up — BGP-learned routes propagate to segment automatically. We left it in place for belt-and-suspenders during the migration window; can be cleaned up post-migration.

## 3. Customer-side change — strongSwan

Switch from policy-based (legacy stroke) to **route-based via xfrm interfaces**:

```
conn aws-tunnel-1
    keyexchange=ikev2
    leftsubnet=0.0.0.0/0          ← any-any ESP, route via xfrm
    rightsubnet=0.0.0.0/0
    mark_in=0x64
    mark_out=0x64
    if_id_in=0x64
    if_id_out=0x64

conn aws-tunnel-2
    ...
    mark_in=0x65
    mark_out=0x65
    if_id_in=0x65
    if_id_out=0x65
```

Then:

```
ip link add xfrm0 type xfrm dev eth0 if_id 0x64
ip link add xfrm1 type xfrm dev eth0 if_id 0x65
ip addr add 169.254.50.106/30  dev xfrm0
ip addr add 169.254.243.142/30 dev xfrm1
```

Routing 192.168.100.0/24 traffic toward AWS now goes via xfrm0 / xfrm1 (FRR's BGP-learned routes pick one, secondary is ECMP fallback). The kernel marks the skb with the xfrm interface's `if_id` on egress; XFRM matches the marked SA; encryption happens. **`if_id` is what makes mark propagation actually work** under modern kernels — iptables-mangle MARK rules fire too late for XFRM lookup.

## 4. Customer-side change — FRR (BGP)

```
router bgp 65000
 bgp router-id 192.168.100.50
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 neighbor AWS-VPN peer-group
 neighbor AWS-VPN remote-as 64513
 neighbor AWS-VPN timers 10 30
 neighbor 169.254.50.105 peer-group AWS-VPN
 neighbor 169.254.50.105 update-source 169.254.50.106
 neighbor 169.254.243.141 peer-group AWS-VPN
 neighbor 169.254.243.141 update-source 169.254.243.142
 address-family ipv4 unicast
  network 192.168.100.0/24
  network 192.168.200.0/24
  neighbor AWS-VPN activate
```

`update-source` is mandatory — without it, FRR sources BGP TCP from the kernel's best-route source (eth0 / 172.31.10.103), which the AWS BGP listener rejects because the source doesn't match the configured peer (CGW inside address).

## 5. Issues encountered (4)

### 5.1 — VTI mark wasn't propagating to XFRM lookup (legacy approach)

**Symptom**: traffic enters legacy VTI interface (visible in `tcpdump -i vti1`), but no encrypted ESP exits eth0. `iptables -t mangle -L OUTPUT -nv` showed 0 packets matching the `MARK --set-mark 43 -o vti1` rule despite packets transiting vti1.

**Diagnosis**: iptables OUTPUT chain processes packets before XFRM policy lookup on egress in this kernel/strongSwan combo. The MARK fires too late. Legacy VTI relies on this fragile ordering.

**Fix**: switch to **xfrm interfaces**. They mark the skb at the netdev driver level with the interface's `if_id`, which XFRM looks up directly. No iptables rules needed. `if_id_in/if_id_out` in strongSwan ipsec.conf bind the mark to the SA.

**Production lesson**: legacy VTI is officially deprecated in favor of xfrm interfaces (kernel ≥4.19, ~2018). Newer reference docs and AWS BGP-VPN configs use xfrm interfaces exclusively. If you see a customer-config example on AWS that mentions VTI specifically, it's likely outdated.

### 5.2 — BGP source-IP mismatch

**Symptom**: BGP sessions stuck in `Active` (TCP can't establish). xfrm interfaces UP with correct inside IPs.

**Diagnosis**: AWS's BGP listener accepts connections only from the configured CGW inside address (e.g. `169.254.50.106`). FRR was sourcing from eth0 (`172.31.10.103`) by default because that was the kernel's best-route source for traffic toward `169.254.50.105`. AWS rejected the SYN.

**Fix**: `neighbor X.X.X.X update-source 169.254.X.106` for each AWS BGP peer. FRR binds the BGP TCP socket to the xfrm-interface inside address; AWS accepts.

**Production lesson**: explicit `update-source` is non-negotiable for any BGP-over-tunnel pattern. The default behavior of "pick whichever IP the route table likes" is hostile to BGP listeners that filter by source IP.

### 5.3 — Wrong AWS-side BGP ASN

**Symptom**: TCP SYN reaches AWS (after `update-source` fix), AWS responds with BGP OPEN, FRR sees the ASN doesn't match `remote-as`, drops the session, retries, drops again.

**Diagnosis**: I assumed AWS used the **destination** edge ASN (us-east-1, where VPC-East lives = 64512). Wrong. AWS uses **the Cloud WAN edge ASN where the VPN attachment is provisioned** (us-west-2 = 64513).

Verified via:
```
$ aws networkmanager get-core-network-change-set ... --policy-version-id 1
us-east-1: ASN 64512
us-west-2: ASN 64513
```

The VPN attachment is at us-west-2 edge; AWS's BGP speaker for that attachment uses 64513.

**Fix**: `neighbor AWS-VPN remote-as 64513`. Sessions established within seconds.

**Production lesson**: in Cloud WAN, the BGP ASN for VPN attachments follows the **VPN attachment's edge location**, not the destination VPC's edge. This differs from traditional VGW + VPN, where the AWS-side ASN is the VGW's own. Always check the change-set or the live edge map before assuming.

### 5.4 — Strongswan `leftupdown` script didn't fire

**Symptom**: `ipsec.conf` had `leftupdown=/etc/strongswan-vti.sh ...` for VTI bring-up; child SAs went to INSTALLED, but vti0/vti1 never appeared.

**Diagnosis**: alpine's strongSwan startup script in 5.9.13 with the legacy `ipsec` (stroke) command runs differently than the swanctl/vici path. The stroke path's leftupdown invocation depends on PLUTO_VERB env var, which wasn't being set the way the script expected.

**Fix (interim)**: create xfrm interfaces manually after IPsec comes up. Move ipsec.conf's tunnel definitions into swanctl's `swanctl.conf` (vici-managed) where the equivalent of `leftupdown` is `start_action = trap` plus `dpd_action = restart` and the VTI/xfrm setup is done out-of-band by an init script that watches the swanctl event stream.

**Permanent fix**: after migration to xfrm interfaces, the leftupdown script becomes simpler and the dependency on PLUTO_VERB is gone. Configure `if_id_in/out` in strongSwan and create the xfrm interfaces once at container boot, before strongSwan starts.

**Production lesson**: alpine's strongSwan packaging uses minimal init wrappers. For real deployments, use swanctl/vici (modern API) and orchestrate VTI/xfrm interface bring-up via a sidecar init container or systemd service unit, not via leftupdown hooks.

## 6. Multi-tenant (TENANT-B)

After BGP came up for TENANT-A (`192.168.100.0/24`), adding TENANT-B was small:

- Add `cpe-east:eth2 ↔ leaf1:Eth5` veth via `containerlab tools veth create` (no full redeploy)
- Configure `leaf1.cfg` to add `interface Ethernet5` access VLAN 200
- Add IP `192.168.200.50/24` on cpe-east eth2
- Add `network 192.168.200.0/24` to FRR's BGP advertisement
- Add static route on leaf2 in TENANT-B VRF: `10.10.0.0/16 → 192.168.200.50`
- Add `192.168.200.0/24 → core_network_arn` to VPC-East subnet RT

No NAT, no shortcuts. Both tenant prefixes are first-class BGP advertisements; AWS installs them into the prod segment routing table; the symmetric pattern of postmortem `01`'s static-route world repeats with TENANT-B.

## 7. Validation

```
cpe-east# show ip bgp summary
Neighbor        V    AS    MsgRcvd MsgSent State/PfxRcd PfxSnt
169.254.50.105  4   64513  47      57       2           4
169.254.243.141 4   64513  45      52       2           4

cpe-east# show ip bgp neighbors 169.254.243.141 advertised-routes
   Network          Next Hop  Path
*> 10.10.0.0/16     0.0.0.0   64513 64512 i      ← re-advertised back, AWS filters
*> 10.20.0.0/16     0.0.0.0   64513 i             ← re-advertised back
*> 192.168.100.0/24 0.0.0.0   i                   ← locally originated, TENANT-A
*> 192.168.200.0/24 0.0.0.0   i                   ← locally originated, TENANT-B

h1 → EC2-East: 5/5, 144-341 ms RTT
h2 → EC2-East: 5/5, 153-415 ms RTT
```

Both tenants reach AWS over the BGP-mode VPN. SNAT chain empty. xfrm interfaces UP with correct inside CIDRs.

## 8. Production lessons

1. **Cloud WAN BGP ASN follows the VPN attachment's edge, not the destination VPC's edge.** This is non-obvious and not documented prominently. Always pull the change-set before configuring `remote-as`.
2. **xfrm interfaces are the modern path; legacy VTI is no longer the right default.** Anything in 2018+ kernels should use `ip link add ... type xfrm if_id N` plus strongSwan's `mark_in/mark_out/if_id_in/if_id_out`. The mark-propagation problems VTI had under newer kernels are eliminated.
3. **`update-source` is required for BGP-over-tunnel.** Don't rely on default route source-IP selection. AWS's BGP listener filters by source.
4. **Both tunnels active is the AWS default in BGP mode; design the customer side to match.** Active/active is the production-grade model — half the latency variance, instant failover, and you're not silently relying on one tunnel that happens to be carrying everything.
5. **Multi-tenant CPE pattern: one IPsec, multiple BGP-advertised prefixes, no NAT.** A single CPE terminating multiple tenants is the realistic branch-site pattern. NAT-mux is a hack; first-class advertisement of each tenant prefix is the canonical answer. AHEAD-grade design.
