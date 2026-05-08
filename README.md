# AWS Cloud WAN — Multi-Region Prototype

A Terraform-deployed AWS Cloud WAN core network connecting two VPCs in two regions, demonstrating segment-based policy and cross-region forwarding.

Built as a portfolio piece demonstrating the IaC pattern I'd land in week 2 of an AWS Cloud WAN engagement.

## Architecture

![topology](diagrams/topology.mmd)

- **Cloud WAN core network** with two segments: `prod` (us-east-1) and `dev` (us-west-2)
- **VPC-East** (10.10.0.0/16) attached to the `prod` segment
- **VPC-West** (10.20.0.0/16) attached to the `dev` segment
- **One EC2 per VPC** (t3.nano, Amazon Linux 2023) for ping testing
- **Attachment policy** uses tag-based association (`Segment=prod` / `Segment=dev`) — production-grade pattern, no hardcoded ARNs
- **Initial policy**: prod ⇆ dev share enabled (so demo pings work)
- **Postmortem 01** (planned): flip the policy to remove sharing, observe blackhole, document the failure mode

## What this proves

| Claim | Evidence |
|---|---|
| I can stand up a Cloud WAN multi-region core | this repo's `terraform apply` |
| I understand segment-based policy | `cloudwan.tf` — `segment-actions` block |
| I can integrate VPCs at scale via tag-based attachment policy | `cloudwan.tf` — `attachment-policies` |
| I write IaC, not click-ops | full Terraform, no console state |
| I know cost discipline | `terraform destroy` removes everything; ~$2 total run cost |

## Deploy

```bash
# 1. Generate an SSH keypair for the EC2 instances
ssh-keygen -t ed25519 -f ~/.ssh/aws_cloudwan_lab -N ''

# 2. Set your laptop's public IP for SSH access (optional but recommended)
export TF_VAR_ssh_my_ip="$(curl -s ifconfig.me)/32"

# 3. Init + plan + apply
cd terraform/
terraform init
terraform plan
terraform apply -auto-approve   # ~10-15 min; Cloud WAN provisioning is slow
```

## Test

```bash
# Pull the helper outputs
terraform output

# SSH into east host
ssh -i ~/.ssh/aws_cloudwan_lab ec2-user@<east_host_public_ip>

# From east host, ping west host's PRIVATE ip — traffic flows over Cloud WAN
ping -c 3 <west_host_private_ip>

# Watch the route tables to confirm CW routes installed
aws ec2 describe-route-tables --region us-east-1 \
  --filters "Name=tag:Project,Values=cloudwan-prototype"
```

## Phase 2 — IPsec extension to on-prem EVPN fabric

The Cloud WAN core only proves itself when traffic actually crosses a customer boundary. Phase 2 adds an AWS Site-to-Site VPN that terminates the `prod` segment on a Linux CPE running inside an on-prem containerlab EVPN fabric, end-to-end ping from EC2 to a tenant host behind the leaf-spine.

This is the same pattern a plasma center uses in production: a CPE at the branch terminates a managed VPN to corporate, the LAN side hands off into a tenant VLAN, and a host on the floor reaches a regional resource without anyone touching the underlay. Same mechanic, smaller blast radius.

### Architecture

See `diagrams/topology.mmd` for the full picture. Summary:

- **AWS side**: a `aws_vpn_connection` (2 tunnels, ESP/IKEv2, NAT-T) terminates on a Cloud WAN VPN attachment tagged `Segment = prod`, so it lands in the same segment as VPC-East. Static routes are used initially; BGP is left for a future iteration. The on-prem subnet `192.168.100.0/24` is added as a static route on the VPN attachment so VPC-East returns through the tunnel.
- **Customer side**: `cpe-east` is an alpine container in the containerlab fabric running strongswan and Linux IP forwarding. It sits inside TENANT-A on VLAN 100 with `192.168.100.50/24` on `eth1` (attached to leaf1's `Ethernet4` as an access port), and uses the clab management bridge for outbound internet. It owns the IPsec endpoint and an iptables FORWARD rule between the tunnel and the tenant interface.
- **Why cpe-east initiates the tunnel** (`auto=start`): the laptop's home router does outbound NAT only — no inbound port-forward for UDP/500, UDP/4500, or ESP. With cpe-east as the initiator, AWS sees the connection coming from the laptop's WAN IP `24.42.204.221` and the NAT mapping is created on the way out. The tunnel survives keepalives without any inbound holes.

### Test path

```
EC2-East 10.10.1.x
  → VPC-East route table (0.0.0.0/0 to core_network_arn)
  → Cloud WAN core (prod segment)
  → S2S VPN attachment (static route 192.168.100.0/24)
  → IPsec tunnel over the public internet
  → home-router NAT
  → cpe-east (192.168.100.50)
  → leaf1 access VLAN 100, TENANT-A VRF
  → EVPN RT-2 lookup for h1's MAC
  → h1 (192.168.100.101)
```

### Cost

VPN connection adds **$0.05/hr** on top of the existing $0.16/hr → **~$0.21/hr** while running. Data-transfer-out from the AWS side is metered separately but trivial for ping-scale tests.

### Sensitive material

The AWS-generated VPN configuration (PSK, tunnel inside CIDRs, AWS-side outside IPs) is exposed via Terraform outputs marked `sensitive = true`. It is **not committed to the repo** — the operator pulls it locally with `terraform output -json vpn_config` and feeds it into the strongswan config on cpe-east. The repo retains only the plumbing (resources, attachments, attachment-policy tags); the secrets stay in local state.

## Tear down

```bash
cd terraform/
terraform destroy -auto-approve   # ~10 min
```

## Cost

- Cloud WAN core network: **$0.05/hr** (~$1.20/day if left running)
- Each VPC attachment: **$0.05/hr each** (×2 = $0.10/hr)
- t3.nano EC2: **$0.005/hr each** (×2 = $0.01/hr)
- Total: **~$0.16/hr running**
- Demo runtime ~3-4 hr → **~$0.65 total cost** if torn down promptly

A CloudWatch billing alarm at $5/day is the recommended safety net.

## Files

```
aws-cloudwan/
├── README.md
├── terraform/
│   ├── versions.tf       # provider config (us-east-1, us-west-2 aliases)
│   ├── variables.tf      # CIDR + region + ssh-IP variables
│   ├── vpcs.tf           # VPCs, subnets, route tables, security groups
│   ├── cloudwan.tf       # global network + core network policy + attachments
│   ├── vpn.tf            # CGW + VPN connection + Cloud WAN VPN attachment (Phase 2)
│   ├── ec2.tf            # test instances + key pair
│   └── outputs.tf        # IPs + ARNs + helper test commands (incl. sensitive vpn_config)
├── diagrams/
│   └── topology.mmd
└── postmortems/
    ├── 00-bring-up-results.md
    └── 01-ipsec-extension.md
```

## Skills demonstrated

- AWS Cloud WAN core network policy (declarative JSON, segments, segment-actions, attachment-policies)
- Multi-region Terraform with provider aliases
- Tag-based attachment policy (production scaling pattern)
- IaC-driven SG/route-table/subnet wiring with cross-resource refs
- Mermaid topology diagrams committed alongside infra
- Cost transparency (this README has hard numbers)
- AWS Site-to-Site VPN with Cloud WAN segment attachment
- On-prem to cloud IPsec termination via Linux strongswan in a Customer Premise Equipment role
- Cross-fabric routing across managed-cloud and on-prem-EVPN domains
