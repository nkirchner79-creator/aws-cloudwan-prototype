# Bring-up evidence — multi-region Cloud WAN fabric

## Apply outcome

```
Apply complete! Resources: 25 added, 0 changed, 0 destroyed.
```

Two issues encountered + resolved during bring-up:

### Issue 1 — Free Plan service-level block on `networkmanager`

First `terraform apply` failed early with:
```
api error SubscriptionRequiredException: The AWS Access Key Id needs a
subscription for the service
```

**Root cause**: account was on AWS new-customer **Free Plan** ($200 credit, 2025+ signup variant), which restricts to a curated subset of services. Cloud WAN (`networkmanager` API) is excluded.

**Fix**: upgraded account to **Paid plan** via Billing Console → "Upgrade plan." Free credits still apply to charges; only the service guardrails go away. One-way migration.

### Issue 2 — `INVALID_ASN_UPDATE` on policy attachment

After core network came up under a stub base policy (16m13s create), the `core_network_policy_attachment` for the real policy failed:

```
Error: waiting for Network Manager Core Network Policy from Core Network
unexpected state 'FAILED_GENERATION', wanted target 'READY_TO_EXECUTE'
```

Pulling the validator output:
```
ErrorCode:  INVALID_ASN_UPDATE
Message:    "ASNs already in use cannot be removed"
Path:       $.core-network-configuration
```

**Root cause**: the stub base policy auto-assigned ASN 64512 (us-east-1 edge) and 64513 (us-west-2 edge). My intended policy declared `asn-ranges = ["64520-64529"]`, which excluded the in-use ASNs. Cloud WAN refuses any policy update that would orphan in-use ASNs.

**Fix**: widen `asn-ranges` to `64512-64529` so the existing edge ASNs fall within the declared range. Re-apply succeeded.

## Connectivity test

`ping -c 5` from EC2-East (10.10.1.124, prod segment, us-east-1) to EC2-West (10.20.1.119, dev segment, us-west-2):

```
PING 10.20.1.119 (10.20.1.119) 56(84) bytes of data.
64 bytes from 10.20.1.119: icmp_seq=1 ttl=125 time=57.7 ms
64 bytes from 10.20.1.119: icmp_seq=2 ttl=125 time=56.0 ms
64 bytes from 10.20.1.119: icmp_seq=3 ttl=125 time=56.0 ms
64 bytes from 10.20.1.119: icmp_seq=4 ttl=125 time=55.9 ms
64 bytes from 10.20.1.119: icmp_seq=5 ttl=125 time=55.8 ms

5 packets transmitted, 5 received, 0% packet loss
rtt min/avg/max/mdev = 55.812/56.289/57.699/0.708 ms
```

`traceroute -n -w 1 -q 1 10.20.1.119` returns only `*` for all intermediate hops — Cloud WAN's managed core network does not expose the underlying spine routers in ICMP-TTL responses. This is **expected and correct behavior** for AWS-managed transport; the segment policy is enforced inside the core network without exposing transit ASNs to the customer.

## Architecture validated

- ✅ Cross-region routing via Cloud WAN segment policy (prod ⇆ dev share)
- ✅ Tag-based attachment association (`Segment = prod` on VPC-East attachment auto-mapped to `prod` segment via `attachment-policies` rule with `tag-value-of-key = "Segment"`)
- ✅ Bidirectional BGP (implicit via Cloud WAN; not exposed to customer route tables)
- ✅ VPC route tables programmed via `core_network_arn` route target — no static route maintenance per VPC

## ASN auto-assignment observation

| Edge | ASN |
|---|---|
| us-west-2 | 64512 |
| us-east-1 | 64513 |

(Confirmed via `aws networkmanager get-core-network-change-set` query — the change-set shows `Action: ADD` for each `CORE_NETWORK_EDGE` with the assigned ASN.)

This is the underlying eBGP infrastructure inside the managed Cloud WAN core. Each edge location runs its own BGP speaker; Cloud WAN abstracts the peering mesh.
