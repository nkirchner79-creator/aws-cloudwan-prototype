################################################################
# Site-to-Site VPN attachment to Cloud WAN
#
# Terminates an IPsec tunnel from the local strongswan endpoint
# (laptop WAN-side public IP) into the Cloud WAN core network's
# "prod" segment via a Site-to-Site VPN attachment.
#
# Cloud WAN VPN attachments are managed in the home region of the
# global network (us-west-2), so the customer gateway and VPN
# connection use the aws.west provider alias.
################################################################

variable "customer_public_ip" {
  description = "Laptop's WAN-side public IP where the strongswan endpoint terminates."
  default     = "24.42.204.221"
}

variable "customer_bgp_asn" {
  description = "BGP ASN advertised by the customer-side strongswan."
  default     = 65000
}

resource "aws_customer_gateway" "cpe_east" {
  provider   = aws.west
  bgp_asn    = var.customer_bgp_asn
  ip_address = var.customer_public_ip
  type       = "ipsec.1"
  tags = {
    Name    = "${var.project}-cpe-east"
    Segment = "prod"
  }
}

resource "aws_vpn_connection" "cpe_east" {
  provider                = aws.west
  customer_gateway_id     = aws_customer_gateway.cpe_east.id
  type                    = "ipsec.1"
  outside_ip_address_type = "PublicIpv4"

  # BGP-based VPN: AWS learns customer prefixes dynamically over BGP
  # sessions running inside each tunnel. Both tunnels become active for
  # data-plane forwarding (ECMP across the BGP-learned next-hops).
  static_routes_only = false

  tags = {
    Name    = "${var.project}-cpe-east"
    Segment = "prod"
  }
}

resource "aws_networkmanager_site_to_site_vpn_attachment" "cpe_east" {
  provider           = aws.global
  core_network_id    = aws_networkmanager_core_network.this.id
  vpn_connection_arn = aws_vpn_connection.cpe_east.arn
  tags = {
    Name    = "${var.project}-cpe-east"
    Segment = "prod"
  }
  depends_on = [aws_networkmanager_core_network_policy_attachment.this]
}

# Static routes are no longer needed once BGP is up — the customer-side
# BGP speaker (FRR on cpe-east) advertises 192.168.100.0/24 dynamically.
# AWS learns it on both tunnels and propagates into the prod segment
# routing table at every Cloud WAN edge automatically.

################################################################
# Outputs — tunnel endpoints, PSKs, inside CIDRs, BGP ASN, and
# the full AWS-generated XML config blob for strongswan setup.
################################################################
output "vpn_aws_tunnel1_address" {
  value = aws_vpn_connection.cpe_east.tunnel1_address
}

output "vpn_aws_tunnel2_address" {
  value = aws_vpn_connection.cpe_east.tunnel2_address
}

output "vpn_aws_tunnel1_preshared_key" {
  value     = aws_vpn_connection.cpe_east.tunnel1_preshared_key
  sensitive = true
}

output "vpn_aws_tunnel2_preshared_key" {
  value     = aws_vpn_connection.cpe_east.tunnel2_preshared_key
  sensitive = true
}

output "vpn_aws_tunnel1_inside_cidr" {
  value = aws_vpn_connection.cpe_east.tunnel1_inside_cidr
}

output "vpn_aws_tunnel2_inside_cidr" {
  value = aws_vpn_connection.cpe_east.tunnel2_inside_cidr
}

output "vpn_aws_tunnel1_bgp_asn" {
  value = aws_vpn_connection.cpe_east.tunnel1_bgp_asn
}

output "vpn_aws_tunnel2_bgp_asn" {
  value = aws_vpn_connection.cpe_east.tunnel2_bgp_asn
}

# AWS-side BGP peer addresses (the .x.169 / .y.93 inside the /30s).
# cpe-east's FRR will peer with both.
output "vpn_aws_tunnel1_vgw_inside_address" {
  value = aws_vpn_connection.cpe_east.tunnel1_vgw_inside_address
}

output "vpn_aws_tunnel2_vgw_inside_address" {
  value = aws_vpn_connection.cpe_east.tunnel2_vgw_inside_address
}

# Customer-side BGP peer addresses (the .x.170 / .y.94).
output "vpn_aws_tunnel1_cgw_inside_address" {
  value = aws_vpn_connection.cpe_east.tunnel1_cgw_inside_address
}

output "vpn_aws_tunnel2_cgw_inside_address" {
  value = aws_vpn_connection.cpe_east.tunnel2_cgw_inside_address
}

output "vpn_xml_config" {
  value     = aws_vpn_connection.cpe_east.customer_gateway_configuration
  sensitive = true
}
