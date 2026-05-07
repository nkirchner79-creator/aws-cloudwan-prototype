variable "project" {
  default = "cloudwan-prototype"
}

variable "region_east" {
  default = "us-east-1"
}

variable "region_west" {
  default = "us-west-2"
}

variable "region_global" {
  default = "us-west-2"
}

variable "vpc_east_cidr" {
  default = "10.10.0.0/16"
}

variable "vpc_west_cidr" {
  default = "10.20.0.0/16"
}

variable "ssh_my_ip" {
  description = "Your laptop's public IP for SSH access; e.g. 'a.b.c.d/32'. Set via TF_VAR_ssh_my_ip."
  default     = "0.0.0.0/0"
}

locals {
  common_tags = {
    Project     = var.project
    Environment = "lab"
    ManagedBy   = "terraform"
    Owner       = "nate"
    AutoDestroy = "true"
  }
}
