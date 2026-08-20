# =============================================================================
# terraform/versions.tf  (root)
# -----------------------------------------------------------------------------
# What Terraform version and providers this whole stack needs. Every module
# also declares its own required_providers (that's how a module documents
# "here's what I need" independently) — but only the ROOT actually configures
# and downloads them. This file is the root's copy of that requirement list.
# =============================================================================
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
