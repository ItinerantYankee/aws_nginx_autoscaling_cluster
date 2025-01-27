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

# Set AMI image ID
variable "ami_image_id" {
  description = "ID of AMI image to use"
  type = string
  default = "ami-07d4ce6c2eb08b4fc"
}

# Set instance type of use
variable "instance_type" {
  description = "EC2 instance type to use"
  type = string
  default = "t2.micro"
}

# Get AWS account ID
data "aws_caller_identity" "current" {}
output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

# Query available availability zones. Store results in 'available_zones'.
data "aws_availability_zones" "available_zones" {
  state = "available"
}

# Create VPC
resource "aws_vpc" "nginx_vpc" {
  cidr_block            = "10.0.0.0/16"
  enable_dns_support    = true
  enable_dns_hostnames  = true
  tags = {
    Name = "Terraform Nginx VPC"
  }
}

# Create subnets
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

# Create security group
resource "aws_security_group" "nginx_security_group" {
  name = "Terraform-Nginx-Security-Group"
  vpc_id = aws_vpc.nginx_vpc.id

  ingress {
    from_port     = 80
    to_port       = 80
    protocol      = "tcp"
    cidr_blocks   = ["0.0.0.0/0"]
  }
  ingress {
    from_port     = 443
    to_port       = 443
    protocol      = "tcp"
    cidr_blocks   = ["0.0.0.0/0"]
  }
  egress {
    from_port     = 0
    to_port       = 0
    protocol      = "-1"
    cidr_blocks   = ["0.0.0.0/0"]
  }
}

# Create Auto-Scaling Group launch configuration (akin to aws_instance)
resource "aws_launch_template" "nginx_asg_template" {
  image_id      = var.ami_image_id
  instance_type = var.instance_type
  vpc_security_group_ids = [aws_security_group.nginx_security_group.id]

  user_data = base64encode(<<-EOF
              echo "Hello, World!" > /var/www/html/index.html
              EOF
              )

  # Required when using a launch configuration with an auto scaling group because ASG references a launch configuration
  #   by name. If the name is changed Terraform won't have the old name to destroy after createing/replacing the new
  #   launch configuration. This setting overrides the normal order of destroy, then created
  lifecycle {
    create_before_destroy = true
  }
}

# Create Auto Scaling Group
resource "aws_autoscaling_group" "nginx_auto_scaling_group" {
  launch_template {
    id = aws_launch_template.nginx_asg_template.id
    version = "$Latest"
  }
  vpc_zone_identifier = aws_subnet.nginx_subnets[*].id

  max_size = 10
  min_size = 3


  tag {
    key                 = "Service"
    propagate_at_launch = false
    value               = "Nginx Cluster"
  }
}

# Output availability zones
output "aws_availability_zones" {
  value = data.aws_availability_zones.available_zones.names
}

# Output subnets
