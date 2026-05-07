################################################################
# Test EC2 instances — t3.nano (cheapest), Amazon Linux 2023
################################################################

# Latest AL2023 AMI per region
data "aws_ami" "al2023_east" {
  provider    = aws.east
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

data "aws_ami" "al2023_west" {
  provider    = aws.west
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# Single SSH key reused in both regions.
# Generate locally:  ssh-keygen -t ed25519 -f ~/.ssh/aws_cloudwan_lab -N ''
# (or substitute the path in TF_VAR_ssh_key_file_path)
variable "ssh_pubkey_path" {
  default = "~/.ssh/aws_cloudwan_lab.pub"
}

resource "aws_key_pair" "east" {
  provider   = aws.east
  key_name   = "${var.project}-key"
  public_key = file(pathexpand(var.ssh_pubkey_path))
}

resource "aws_key_pair" "west" {
  provider   = aws.west
  key_name   = "${var.project}-key"
  public_key = file(pathexpand(var.ssh_pubkey_path))
}

resource "aws_instance" "east" {
  provider                    = aws.east
  ami                         = data.aws_ami.al2023_east.id
  instance_type               = "t3.nano"
  subnet_id                   = aws_subnet.east.id
  vpc_security_group_ids      = [aws_security_group.east.id]
  key_name                    = aws_key_pair.east.key_name
  associate_public_ip_address = true
  tags                        = { Name = "${var.project}-east-host" }
}

resource "aws_instance" "west" {
  provider                    = aws.west
  ami                         = data.aws_ami.al2023_west.id
  instance_type               = "t3.nano"
  subnet_id                   = aws_subnet.west.id
  vpc_security_group_ids      = [aws_security_group.west.id]
  key_name                    = aws_key_pair.west.key_name
  associate_public_ip_address = true
  tags                        = { Name = "${var.project}-west-host" }
}
