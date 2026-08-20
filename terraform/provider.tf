# =============================================================================
# terraform/provider.tf  (root)
# -----------------------------------------------------------------------------
# Points the AWS provider at LocalStack instead of real AWS, using LocalStack's
# well-known fake credentials (account 000000000000). This is written out
# explicitly (rather than relying on the `tflocal` wrapper to patch it in)
# so plain `terraform` works the same way `tflocal` does in CI — one less
# thing that behaves differently between your laptop and the pipeline.
#
# Only endpoints for services this stack actually calls are listed. If Lwam's
# module ends up using something not listed here (e.g. iam), add it below —
# LocalStack will otherwise silently fall through to trying real AWS for that
# one service, which fails loudly (no credentials) rather than quietly, so
# it's an easy bug to catch.
# =============================================================================
provider "aws" {
  region = var.aws_region

  access_key = "test"
  secret_key = "test"

  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2            = "http://localhost:4566"
    rds            = "http://localhost:4566"
    secretsmanager = "http://localhost:4566"
    elb            = "http://localhost:4566"
    elbv2          = "http://localhost:4566"
    sts            = "http://localhost:4566"
  }
}
