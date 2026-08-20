# Provider requirements for the service module. Only the AWS provider is used —
# user-data is rendered with the built-in templatefile() function rather than a
# template provider, so there is nothing else to declare here.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
