# Recruiter reply draft — AHEAD Senior AWS Network Engineer

> Updated 2026-05-08. Reflects the working state of the lab + portfolio repo at github.com/nkirchner79-creator/aws-cloudwan-prototype.

---

```
Subject: re: Senior AWS Network Engineer — AHEAD / Connected Enterprise

Hi [name],

Thanks for reaching out — yes, interested. Quick on the fit:

— 25 years enterprise multi-site network engineering (theater WAN
  across 23 countries, 80K-seat geo-redundant UC architected greenfield,
  classified+unclassified parallel networks).

— Most recent: 3 years at Arista Networks (TAC, Fortune 500 + hyperscale,
  VXLAN/EVPN fabrics).

— I have a working multi-region AWS Cloud WAN deployment on my own AWS
  account, integrated end-to-end with an on-prem EVPN/VXLAN fabric over
  IPsec + BGP. Both tenants on the on-prem side reach the AWS VPCs via
  segment-aware Cloud WAN routing; multi-tenant CPE pattern. Repo +
  bring-up postmortems at
  github.com/nkirchner79-creator/aws-cloudwan-prototype.
  Happy to walk through it on screen.

— Stack: Terraform (AWS provider 5.x), AWS Cloud WAN + Site-to-Site VPN
  + BGP-mode attachment, strongSwan (xfrm interfaces) + FRR for the
  on-prem CPE, Arista cEOS-lab (containerlab) for the EVPN/VXLAN fabric,
  Mermaid diagrams.

— PCNSE recert in flight; available to start next week, remote W2 or 1099.

Could you share the rate band, location/remote setup, and start timing?
Happy to set up a quick call once the basics line up.

Nate Kirchner
nkirchner79@gmail.com
```

---

## What's behind the GitHub link (for context, not for the email)

| Layer | What's deployed |
|---|---|
| **Cloud** | Cloud WAN multi-region (us-east-1 + us-west-2), 2 segments (`prod` ⇆ `dev`), tag-driven attachment policy, `create-route` segment-actions for on-prem prefixes |
| **VPN** | AWS Site-to-Site VPN attached to Cloud WAN `prod` segment, BGP-mode (`static_routes_only=false`), 2 tunnels both ESTABLISHED |
| **CPE** | Linux container (alpine + strongSwan + FRR 10.0), xfrm interfaces (modern replacement for legacy VTI), BGP peering both AWS tunnels, advertises both tenant prefixes |
| **On-prem fabric** | 4-node cEOS-lab containerlab (2 spines AS 65000, 2 leaves AS 65101/65102), eBGP underlay + eBGP-EVPN overlay, symmetric IRB, anycast gateway, 2 tenants (TENANT-A / TENANT-B) with own VRFs + SVIs + L2/L3 VNIs |
| **Multi-tenant** | Both TENANT-A (192.168.100.0/24) and TENANT-B (192.168.200.0/24) reach AWS VPC-East via the same CPE; advertised first-class via BGP, no NAT shortcut |
| **Validated end-to-end** | h1 (TENANT-A) → EC2-East: 0% loss. h2 (TENANT-B) → EC2-East: 0% loss. ~150-220ms RTT (cross-region IPsec + BGP path). |

## Why each technology is in the stack

| Tool | Role | Why |
|---|---|---|
| **Terraform** (1.15.2) | All AWS resource provisioning | declarative, GitOps-able, peer-reviewable in PRs |
| **AWS Cloud WAN** | Multi-region core network with policy-as-code segments | the JD's named technology |
| **AWS Site-to-Site VPN** | Encrypted on-prem ↔ Cloud WAN bridge | natively attaches to Cloud WAN, BGP-capable |
| **strongSwan** (xfrm interfaces) | Customer-side IPsec | modern Linux IPsec; xfrm interfaces are the 2024+ canonical replacement for legacy VTI |
| **FRR 10.0** (zebra + bgpd) | Customer-side BGP | open-source, Cisco-like CLI (`vtysh`), de facto for Linux network appliances (Cumulus, SONiC, VyOS) |
| **Arista cEOS-lab** | On-prem EVPN/VXLAN fabric | matches AHEAD-relevant production gear; enables real BGP/EVPN + VXLAN testing |
| **Containerlab** | Lab orchestration | reproducible, single-yaml topology, integrates with cEOS-lab |
| **Mermaid + markdown** | Architecture diagrams + postmortems | text-tracked, diff-able alongside the IaC |

## Repo structure

```
aws-cloudwan-prototype/
├── README.md                       # what + cost transparency
├── docs/
│   ├── design.md                   # technical design doc (no fluff)
│   └── recruiter-reply-draft.md    # this file
├── terraform/                      # all IaC
│   ├── versions.tf                 # AWS provider 5.x, multi-region
│   ├── variables.tf                # CIDRs, regions, project tag
│   ├── vpcs.tf                     # 2 VPCs + subnets + IGWs + RTs + SGs
│   ├── cloudwan.tf                 # global network + core network + policy + VPC attachments
│   ├── vpn.tf                      # CGW + S2S VPN (BGP mode) + Cloud WAN VPN attachment
│   ├── ec2.tf                      # test EC2 t3.nano per VPC
│   └── outputs.tf                  # IPs, ARNs, BGP peer addrs
├── diagrams/
│   └── topology.mmd                # Mermaid topology
└── postmortems/
    ├── 00-bring-up-results.md      # initial Cloud WAN multi-region bring-up — 2 issues fixed
    ├── 01-ipsec-extension.md       # IPsec + on-prem extension — 4 issues fixed
    └── 02-bgp-migration.md         # static-route → BGP — 4 more issues fixed
```

## The "war story" content (postmortems)

10+ real failure modes diagnosed and resolved during the build. Each is a single-page postmortem with: symptom, diagnostic path, root cause, fix, production lesson. Examples:

- AWS Free Plan service-level block on `networkmanager` — fix: upgrade billing plan
- `INVALID_ASN_UPDATE` on policy attachment — fix: ASN ranges in the policy must always be a superset of currently-assigned ASNs
- Cloud WAN segment routing table missing the on-prem prefix even though `aws_vpn_connection_route` was set — fix: explicit `create-route` segment-action in the policy
- strongSwan dual-tunnel XFRM template mismatch under legacy VTI — fix: switch to xfrm interfaces with `mark_in/mark_out`
- BGP peer ASN mismatch (assumed wrong Cloud WAN edge ASN) — fix: AWS uses the **VPN-attachment-local edge ASN**, not the destination VPC's edge

That last one is the kind of insight that's hard-earned and interview-grade.
