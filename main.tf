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
}

# Set AMI image ID
variable "ami_image_id" {
  description = "ID of AMI image to use"
  type = string
}

# Set instance type of use
variable "instance_type" {
  description = "EC2 instance type to use"
  type = string
  default = "t2.micro"
}

variable "cluster_name" {
  description = "Name of cluster to be used in DNS name"
  type = string
}

variable "domain" {
  description = "Hosted zone name. E.g. example.com"
  type = string
}

# Get AWS account ID
data "aws_caller_identity" "current" {}

# Get hosted zone information. Need Zone ID.
data "aws_route53_zone" "zone_info" {
  name = var.domain
}

# Request ACM Certificate
resource "aws_acm_certificate" "nginx_certificate" {
  domain_name = "${var.cluster_name}.${var.domain}"
  validation_method = "DNS"
}

# Create the DNS validation record(s) from the challenge returned by ACM in the aws_acm_certificate object
resource "aws_route53_record" "nginx_cert_validation" {
  for_each = {
    # Loop over each if multiple FQDN are attached to the request
    for dvo in aws_acm_certificate.nginx_certificate.domain_validation_options :
    dvo.domain_name => {
      name = dvo.resource_record_name
      type = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  name    = each.value.name
  type    = each.value.type
  records = [each.value.value]
  zone_id = data.aws_route53_zone.zone_info.zone_id
  ttl     = 300
}

# Wait for certificate validation to complete
resource "aws_acm_certificate_validation" "nginx_cert_validation" {
  certificate_arn = aws_acm_certificate.nginx_certificate.arn
  validation_record_fqdns = [for record in aws_route53_record.nginx_cert_validation : record.fqdn]
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

# Create an Internet Gateway and attach it to the VPC created above.
resource "aws_internet_gateway" "nginx-internet-gateway" {
  vpc_id = aws_vpc.nginx_vpc.id

  tags = {
    Name = "Nginx-Internet-Gateway"
  }
}

# Create route table attached to the new VPC
resource "aws_route_table" "nginx_route_table_to_internet_gateway" {
  vpc_id         = aws_vpc.nginx_vpc.id

  tags = {
    Name = "Nginx-IG-Route_Table"
  }
}

# Create a default route that points to the Internet gateway
resource "aws_route" "nginx_route_to_IG" {
  route_table_id = aws_route_table.nginx_route_table_to_internet_gateway.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.nginx-internet-gateway.id
}

# Associate the route created above with each of the subnets created above
resource "aws_route_table_association" "nginx_route_table_association" {
  count = length(aws_subnet.nginx_subnets)
  subnet_id = aws_subnet.nginx_subnets[count.index].id
  route_table_id = aws_route_table.nginx_route_table_to_internet_gateway.id
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
  name = "Nginx-Launch-Template"
  image_id      = var.ami_image_id
  instance_type = var.instance_type
  vpc_security_group_ids = [aws_security_group.nginx_security_group.id]

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "Nginx Instance"
    }
  }

  user_data = base64encode(<<-EOF
              echo "Hello, World!" > /var/www/html/index.html
              EOF
              )


}

# Create Auto Scaling Group
resource "aws_autoscaling_group" "nginx_auto_scaling_group" {
  name = "Nginx-Auto-Scaling-Group"
  launch_template {
    id = aws_launch_template.nginx_asg_template.id
    version = "$Latest"
  }
  vpc_zone_identifier = aws_subnet.nginx_subnets[*].id

  max_size = 10
  min_size = 3

  target_group_arns = [aws_alb_target_group.nginx_target_group.arn]
  health_check_type = "ELB"
  health_check_grace_period = 300

  tag {
    key                 = "Service"
    propagate_at_launch = false
    value               = "Nginx Cluster"
  }
}

# Create Application Load Balancer
resource "aws_lb" "nginx_alb" {
  name = "Nginx-ALB"
  load_balancer_type = "application"
  subnets = aws_subnet.nginx_subnets[*].id
  security_groups = [aws_security_group.nginx_security_group.id]

}

# Create HTTP Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.nginx_alb.arn
  port = 80
  protocol = "HTTP"

  # Default action if requests don't match any listener rules
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: Page Not Found"
      status_code = 404
    }
  }
}

# Create HTTPS Listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.nginx_alb.arn
  port = 443
  protocol = "HTTPS"
  certificate_arn = aws_acm_certificate.nginx_certificate.arn

  # Default action if requests don't match any listener rules
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: Page Not Found"
      status_code = 404
    }
  }
}

# Create HTTP Listener Rule
resource "aws_lb_listener_rule" "nginx_alb_http_rule" {
  listener_arn = aws_lb_listener.http.arn
  priority = 100

  action {
    type = "forward"
    target_group_arn = aws_alb_target_group.nginx_target_group.arn
  }

  condition {
    path_pattern {
      values = ["*"]
    }
  }
}

# Create HTTPs Listener Rule
resource "aws_lb_listener_rule" "nginx_alb_https_rule" {
  listener_arn = aws_lb_listener.https.arn
  priority = 100

  action {
    type = "forward"
    target_group_arn = aws_alb_target_group.nginx_target_group.arn
  }

  condition {
    path_pattern {
      values = ["*"]
    }
  }
}

# Create a target group
resource "aws_alb_target_group" "nginx_target_group" {
  name = "Nginx-ASG-Target-Group"
  port = 80
  protocol = "HTTP"
  vpc_id = aws_vpc.nginx_vpc.id

  health_check {
    path = "/"
    healthy_threshold = 3
    unhealthy_threshold = 5
  }
}

# Create a DNS record for the FQDN that points to the ALB
resource "aws_route53_record" "nginx_itinerant_yankee_com" {
  name    = "${var.cluster_name}.${var.domain}"
  type    = "A"
  zone_id = data.aws_route53_zone.zone_info.zone_id

  alias {
    evaluate_target_health = true
    name = aws_lb.nginx_alb.dns_name
    zone_id = aws_lb.nginx_alb.zone_id
  }
}

# Output variables
output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
output "aws_availability_zones" {
  value = data.aws_availability_zones.available_zones.names
}
output "domain" {
  value = var.domain
}


# Output subnets
