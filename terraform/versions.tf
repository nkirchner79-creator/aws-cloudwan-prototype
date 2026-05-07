terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  alias  = "east"
  region = var.region_east
  default_tags { tags = local.common_tags }
}

provider "aws" {
  alias  = "west"
  region = var.region_west
  default_tags { tags = local.common_tags }
}

# Global network mgmt always lives in us-west-2 by AWS convention; no harm
# making it explicit. Cloud WAN itself is global; the API endpoint just lives
# in one home region.
provider "aws" {
  alias  = "global"
  region = var.region_global
  default_tags { tags = local.common_tags }
}
