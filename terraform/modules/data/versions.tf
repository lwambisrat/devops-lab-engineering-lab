# Provider requirements for the data module. random_password is gone (Aiven
# owns the password now), so this module no longer needs hashicorp/random —
# only aws, for the Secrets Manager resources.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
