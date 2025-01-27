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

variable "number_of_subnets" {
  description = "Number of subnets to spread the instances over."
  type = number
  default = 3
}
variable "number_instances_in_each_subnet" {
  description = "Number of Nginx instances to created in each subnet"
  type = number
  default = 2
}
variable "domain" {
  description = "Hosted zone name. E.g. example.com"
  type = string
  default = "itinerantyankee.com"
}
variable "cluster_name" {
  description = "Name of cluster. e.g. nginx.example.com"
  type = string
  default = "nginx"
}

provider "aws" {
  # Configure the aws provider
  region = "us-east-1"
  profile = "default"
}

# Get account number
data "aws_caller_identity" "current" {}
output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

data "aws_availability_zones" "available_zones" {
  # Query available availability zones. Store results in 'available_zones'.
  state = "available"
}

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
  # The cidrsubnet function returns a value subnet from main CIDR block. E.g. cidrsubnet("10.0.0.0/16", 8, 1) → 10.0.1.0/24
  # The availability zone is assigned based on the results of the query above and the current count index.
  count                 = 3
  vpc_id                = aws_vpc.nginx_vpc.id
  cidr_block            = cidrsubnet(aws_vpc.nginx_vpc.cidr_block, 8, count.index)
  availability_zone     = data.aws_availability_zones.available_zones.names[count.index]
  tags = {
    Name = "Terraform Nginx-Subnet-${count.index + 1}"
  }
 } 

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

resource "aws_instance" "nginx-server" {
  # Creates specified number on EC2 instances in each subnet
  count         = var.number_of_subnets * var.number_instances_in_each_subnet
  ami           = "ami-07d4ce6c2eb08b4fc"
  instance_type = "t2.micro"
  subnet_id = aws_subnet.nginx_subnets[floor(count.index / var.number_instances_in_each_subnet)].id
  security_groups = [aws_security_group.nginx_security_group.id]
  tags = {
    Name = "Terraform-Nginx-Server-${floor(count.index / var.number_instances_in_each_subnet) + 1}-${count.index % var.number_instances_in_each_subnet + 1}"
  }
}

# Create S3 bucket to store ALB logs
resource "random_string" "nginx_alb_access_log_bucket_prefix" {
  length = 16
  special = false
  upper = false
}
resource "aws_s3_bucket" "nginx_alb_access_logs_bucket" {
  bucket = "nginx-alb-access-logs-${random_string.nginx_alb_access_log_bucket_prefix.result}"
}

# Create IAM policy to allow ALB to write to S3 bucket
resource "aws_s3_bucket_policy" "nginx_alb_access_logs_policy" {
  bucket = aws_s3_bucket.nginx_alb_access_logs_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "AllowELBLogging",
        Effect = "Allow",
        Principal = {
          Service = "elasticloadbalancing.amazonaws.com"
        },
        Action = "s3:PutObject",
        Resource = "${aws_s3_bucket.nginx_alb_access_logs_bucket.arn}/*",
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          },
          ArnLike = {
            # "aws:SourceArn" = "arn:aws:elasticloadbalancing:${data.aws_region}:${data.aws_caller_identity.current.account_id}:loadbalancer/app/*"
          }
        }
      }]
  })
}

resource "aws_lb_target_group" "nginx_target_group" {
  # Create an load balancer target group
  name = "Nginx-Target-Group"
  protocol = "HTTP"
  port = 80
  vpc_id = aws_vpc.nginx_vpc.id
  target_type = "instance"

  health_check {
    path = "/"
    interval = 30   # seconds
    timeout = 5     # seconds
    healthy_threshold = 3
    unhealthy_threshold = 3
    matcher = "200-299"
  }

  tags = {
    Name = "Nginx-Target-Group"
  }
}

resource "aws_lb_target_group_attachment" "nginx_target_group_attachment" {
  # Attached the EC2 instances to the target group
  count = var.number_of_subnets * var.number_instances_in_each_subnet
  target_group_arn = aws_lb_target_group.nginx_target_group.arn
  target_id = aws_instance.nginx-server[count.index].id
  port = 80
}

# Create an internal application load balancer
resource "aws_lb" "nginx_lb" {
  name = "nginx-alb"
  internal = false
  load_balancer_type = "application"
  subnets = [for subnet in aws_subnet.nginx_subnets: subnet.id]
  security_groups = [aws_security_group.nginx_security_group.id]
}

# Create an HTTP listener for the load balancer
resource "aws_lb_listener" "nginx-http-listener" {
  load_balancer_arn = aws_lb.nginx_lb.arn
  port = 80
  protocol = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.nginx_target_group.arn
  }
}

# Create HTTPS listener for the load balancer
resource "aws_lb_listener" "nginx-https-listener" {
  load_balancer_arn = aws_lb.nginx_lb.arn
  port = 443
  protocol = "HTTPS"
  certificate_arn = aws_acm_certificate.nginx_certificate.arn

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.nginx_target_group.arn
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

# Create a DNS record for the FQDN that points to the ALB
resource "aws_route53_record" "nginx_itinerant_yankee_com" {
  name    = "${var.cluster_name}.${var.domain}"
  type    = "A"
  zone_id = data.aws_route53_zone.zone_info.zone_id

  alias {
    evaluate_target_health = true
    name                   = aws_lb.nginx_lb.dns_name
    zone_id                = aws_lb.nginx_lb.zone_id
  }
}

# Create WAF Web ACL
resource "aws_wafv2_web_acl" "nginx_waf_web_acl" {
  name  = "nginx_waf_web_acl"
  scope = "REGIONAL"              # Use "CLOUDFRONT" for global distribution

  default_action {
    allow {}
  }

  rule {
    name     = "nginx-aws-managed-common"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "nginx-aws-managed-common"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "nginx_waf_web_acl"
    sampled_requests_enabled   = true
  }
}

# Create Cloudwatch Log Group
resource "aws_cloudwatch_log_group" "nginx_waf_log_group" {
  name = "aws-waf-logs-nginx-cluster"
  retention_in_days = 30
}

# Create IAM Role for WAF to write logs
resource "aws_iam_role" "waf_logging_role" {
  name = "WAFLoggingRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "wafv2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }]
  })
}

# Create IAM WAF logging policy to allow logging to the CloudWatch group created above
resource "aws_iam_policy" "nginx_waf_logging_policy" {
  name = "WAFLoggingPolicy"
  description = "Policy to allow WAF logging to CloudWatch"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams"
      ],
      Resource = aws_cloudwatch_log_group.nginx_waf_log_group.arn
    }]
  })
}

# Connect to the WAF logging policy to the WAF IAM role
resource "aws_iam_role_policy_attachment" "waf_logging_policy_attach" {
  policy_arn = aws_iam_policy.nginx_waf_logging_policy.arn
  role       = aws_iam_role.waf_logging_role.name
}

# Debug
output "waf_acl_arn" {
  value = aws_wafv2_web_acl.nginx_waf_web_acl.arn
}
output "cloudwatch_log_group_arn" {
  value = aws_cloudwatch_log_group.nginx_waf_log_group.arn
}

# Enable logging for the WAF ACL created above
resource "aws_wafv2_web_acl_logging_configuration" "nginx_waf_logging" {

  resource_arn = aws_wafv2_web_acl.nginx_waf_web_acl.arn
  log_destination_configs = [aws_cloudwatch_log_group.nginx_waf_log_group.arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}


