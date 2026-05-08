################################################################
# VPC-East — us-east-1, segment "prod"
################################################################
resource "aws_vpc" "east" {
  provider             = aws.east
  cidr_block           = var.vpc_east_cidr
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-east", Segment = "prod" }
}

resource "aws_subnet" "east" {
  provider                = aws.east
  vpc_id                  = aws_vpc.east.id
  cidr_block              = cidrsubnet(var.vpc_east_cidr, 8, 1) # 10.10.1.0/24
  availability_zone       = "${var.region_east}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-east-public" }
}

resource "aws_internet_gateway" "east" {
  provider = aws.east
  vpc_id   = aws_vpc.east.id
  tags     = { Name = "${var.project}-east-igw" }
}

resource "aws_route_table" "east" {
  provider = aws.east
  vpc_id   = aws_vpc.east.id
  tags     = { Name = "${var.project}-east-rt" }
}

resource "aws_route" "east_default" {
  provider               = aws.east
  route_table_id         = aws_route_table.east.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.east.id
}

# Route to remote VPC over Cloud WAN
resource "aws_route" "east_to_west" {
  provider               = aws.east
  route_table_id         = aws_route_table.east.id
  destination_cidr_block = var.vpc_west_cidr
  core_network_arn       = aws_networkmanager_core_network.this.arn
  depends_on             = [aws_networkmanager_vpc_attachment.east]
}

# Routes to on-prem tenant subnets over Cloud WAN VPN
resource "aws_route" "east_to_tenant_a" {
  provider               = aws.east
  route_table_id         = aws_route_table.east.id
  destination_cidr_block = "192.168.100.0/24"
  core_network_arn       = aws_networkmanager_core_network.this.arn
  depends_on             = [aws_networkmanager_site_to_site_vpn_attachment.cpe_east]
}

resource "aws_route" "east_to_tenant_b" {
  provider               = aws.east
  route_table_id         = aws_route_table.east.id
  destination_cidr_block = "192.168.200.0/24"
  core_network_arn       = aws_networkmanager_core_network.this.arn
  depends_on             = [aws_networkmanager_site_to_site_vpn_attachment.cpe_east]
}

resource "aws_route_table_association" "east" {
  provider       = aws.east
  subnet_id      = aws_subnet.east.id
  route_table_id = aws_route_table.east.id
}

resource "aws_security_group" "east" {
  provider    = aws.east
  vpc_id      = aws_vpc.east.id
  name        = "${var.project}-east-sg"
  description = "Allow SSH from operator and ICMP across the fabric"

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_my_ip]
  }
  ingress {
    description = "ICMP from any RFC1918"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-east-sg" }
}

################################################################
# VPC-West — us-west-2, segment "dev"
################################################################
resource "aws_vpc" "west" {
  provider             = aws.west
  cidr_block           = var.vpc_west_cidr
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-west", Segment = "dev" }
}

resource "aws_subnet" "west" {
  provider                = aws.west
  vpc_id                  = aws_vpc.west.id
  cidr_block              = cidrsubnet(var.vpc_west_cidr, 8, 1) # 10.20.1.0/24
  availability_zone       = "${var.region_west}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-west-public" }
}

resource "aws_internet_gateway" "west" {
  provider = aws.west
  vpc_id   = aws_vpc.west.id
  tags     = { Name = "${var.project}-west-igw" }
}

resource "aws_route_table" "west" {
  provider = aws.west
  vpc_id   = aws_vpc.west.id
  tags     = { Name = "${var.project}-west-rt" }
}

resource "aws_route" "west_default" {
  provider               = aws.west
  route_table_id         = aws_route_table.west.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.west.id
}

resource "aws_route" "west_to_east" {
  provider               = aws.west
  route_table_id         = aws_route_table.west.id
  destination_cidr_block = var.vpc_east_cidr
  core_network_arn       = aws_networkmanager_core_network.this.arn
  depends_on             = [aws_networkmanager_vpc_attachment.west]
}

resource "aws_route_table_association" "west" {
  provider       = aws.west
  subnet_id      = aws_subnet.west.id
  route_table_id = aws_route_table.west.id
}

resource "aws_security_group" "west" {
  provider    = aws.west
  vpc_id      = aws_vpc.west.id
  name        = "${var.project}-west-sg"
  description = "Allow SSH from operator and ICMP across the fabric"

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_my_ip]
  }
  ingress {
    description = "ICMP from any RFC1918"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-west-sg" }
}
