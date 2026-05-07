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
│   ├── ec2.tf            # test instances + key pair
│   └── outputs.tf        # IPs + ARNs + helper test commands
├── diagrams/
│   └── topology.mmd
└── postmortems/
    └── (deliberate-failure write-ups go here)
```

## Skills demonstrated

- AWS Cloud WAN core network policy (declarative JSON, segments, segment-actions, attachment-policies)
- Multi-region Terraform with provider aliases
- Tag-based attachment policy (production scaling pattern)
- IaC-driven SG/route-table/subnet wiring with cross-resource refs
- Mermaid topology diagrams committed alongside infra
- Cost transparency (this README has hard numbers)
