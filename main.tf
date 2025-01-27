terraform {
  required_providers {
    # Metadata about required providers
    aws = {
      source = "hashicorp/aws"       # registry.terraform.io/hashicorp/aws
      version = "5.78.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.2"
    }
  }

  required_version = ">= 1.2.0"       # Refers to Terraform CLI version
}

# Configure the aws provider
provider "aws" {

  region = "us-east-1"
  profile = "default"
}

# Set number of subnets to create
variable "number_of_subnets" {
  description = "Number of subnets to spread the instances over."
  type = number
  default = 4
}

# Get AWS account ID
data "aws_caller_identity" "current" {}
output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

data "aws_availability_zones" "available_zones" {
  # Query available availability zones. Store results in 'available_zones'.
  state = "available"
}

resource "aws_vpc" "nginx_vpc" {
  # Configures AWS VPC resource. First arg is resource type. Send arg is resource name.
  cidr_block            = "10.0.0.0/16"
  enable_dns_support    = true
  enable_dns_hostnames  = true
  tags = {
    Name = "Terraform Nginx VPC"
  }
}

resource "aws_subnet" "nginx_subnets" {
  # The count parameter results in a loop repeated 3 times. Use 'count.index' to access the index of the current loop.
  # The cidrsubnet function returns a subnet from main CIDR block. E.g. cidrsubnet("10.0.0.0/16", 8, 1) → 10.0.1.0/24
  # The availability zone is assigned based on the results of the query for available zones stored in the data object
  #   and the current count index.
  count                 = var.number_of_subnets
  vpc_id                = aws_vpc.nginx_vpc.id
  cidr_block            = cidrsubnet(aws_vpc.nginx_vpc.cidr_block, 8, count.index)
  availability_zone     = data.aws_availability_zones.available_zones.names[count.index]
  tags = {
    Name = "Terraform Nginx-Subnet-${count.index + 1}"
  }
}

output "aws_availability_zones" {
  value = data.aws_availability_zones.available_zones.names
}