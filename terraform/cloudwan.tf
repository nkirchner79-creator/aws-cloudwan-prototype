################################################################
# Global Network — account-wide handle for Cloud WAN
################################################################
resource "aws_networkmanager_global_network" "this" {
  provider    = aws.global
  description = "${var.project} global network"
  tags        = { Name = "${var.project}-gn" }
}

################################################################
# Core Network Policy
#
# Two segments (prod for VPC-East, dev for VPC-West) plus an
# attachment-policy that uses the Segment tag on each VPC
# attachment to associate it automatically. Initial sharing
# rule allows prod ⇆ dev so end-to-end pings work; flip the
# segment-actions block to demonstrate isolation.
################################################################
locals {
  core_network_policy = {
    version = "2021.12"
    "core-network-configuration" = {
      "asn-ranges" = ["64512-64529"]
      "edge-locations" = [
        { location = var.region_east },
        { location = var.region_west },
      ]
    }
    segments = [
      {
        name                            = "prod"
        "require-attachment-acceptance" = false
        description                     = "production segment - VPC-East"
      },
      {
        name                            = "dev"
        "require-attachment-acceptance" = false
        description                     = "development segment - VPC-West"
      },
    ]
    "segment-actions" = [
      {
        action       = "share"
        mode         = "attachment-route"
        segment      = "prod"
        "share-with" = ["dev"]
      },
      # Inject the on-prem prefix (TENANT-A overlay) into the prod segment
      # routing table at every edge, pointed at the VPN attachment. Without
      # this, Cloud WAN's prod segment has no route for 192.168.100.0/24
      # even though the VPN attachment carries a static route — segment-level
      # routing requires explicit policy.
      {
        action                    = "create-route"
        segment                   = "prod"
        "destination-cidr-blocks" = ["192.168.100.0/24"]
        # Avoid Terraform dep cycle: VPN attachment is created after policy.
        # Use the AttachmentId placeholder syntax that Cloud WAN policy
        # resolves at runtime via the vpn-attachment route.
        destinations              = ["attachment-0bbc31075a04b7019"]
      },
    ]
    "attachment-policies" = [
      {
        "rule-number"     = 100
        "condition-logic" = "or"
        conditions = [
          { type = "tag-exists", key = "Segment" },
        ]
        action = {
          "association-method" = "tag"
          "tag-value-of-key"   = "Segment"
        }
      },
    ]
  }
}

################################################################
# Core network — start with a stub base policy so the resource
# reaches AVAILABLE; the real policy is then attached below.
################################################################
resource "aws_networkmanager_core_network" "this" {
  provider             = aws.global
  global_network_id    = aws_networkmanager_global_network.this.id
  description          = "${var.project} core network"
  create_base_policy   = true
  base_policy_regions  = [var.region_east, var.region_west]
  tags                 = { Name = "${var.project}-cn" }
}

resource "aws_networkmanager_core_network_policy_attachment" "this" {
  provider        = aws.global
  core_network_id = aws_networkmanager_core_network.this.id
  policy_document = jsonencode(local.core_network_policy)
}

################################################################
# VPC Attachments — tagged so the attachment-policy associates
# them to the right segment automatically.
################################################################
resource "aws_networkmanager_vpc_attachment" "east" {
  provider        = aws.east
  core_network_id = aws_networkmanager_core_network.this.id
  vpc_arn         = aws_vpc.east.arn
  subnet_arns     = [aws_subnet.east.arn]
  tags            = { Name = "${var.project}-att-east", Segment = "prod" }
  depends_on      = [aws_networkmanager_core_network_policy_attachment.this]
}

resource "aws_networkmanager_vpc_attachment" "west" {
  provider        = aws.west
  core_network_id = aws_networkmanager_core_network.this.id
  vpc_arn         = aws_vpc.west.arn
  subnet_arns     = [aws_subnet.west.arn]
  tags            = { Name = "${var.project}-att-west", Segment = "dev" }
  depends_on      = [aws_networkmanager_core_network_policy_attachment.this]
}
