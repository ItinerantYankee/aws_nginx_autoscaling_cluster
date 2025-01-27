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

