# =============================================================================
# terraform/backend.tf  (root)
# -----------------------------------------------------------------------------
# This block is deliberately left almost empty. Terraform backend blocks can't
# use variables (${var.xxx}) — the backend has to be known before Terraform
# has even read your tfvars. So the real values (which bucket, which state
# file "key" for THIS person) get passed in at `terraform init` time instead,
# using -backend-config flags. The Makefile (Step 3) will build those flags
# for you automatically. For now, here's what init looks like by hand:
#
#   terraform init \
#     -backend-config="bucket=regional-health-tfstate" \
#     -backend-config="dynamodb_table=regional-health-tflock" \
#     -backend-config="region=us-east-1" \
#     -backend-config="key=rh/lwam/terraform.tfstate" \
#     -backend-config="endpoints={s3=\"http://localhost:4566\",dynamodb=\"http://localhost:4566\"}" \
#     -backend-config="skip_credentials_validation=true" \
#     -backend-config="skip_metadata_api_check=true" \
#     -backend-config="skip_region_validation=true" \
#     -backend-config="use_path_style=true"
#
# The bucket + lock table are SHARED (everyone's state lives in the same
# bucket) — the "key" is what keeps each person's state on its own page, so
# your apply doesn't overwrite another stack.
# =============================================================================
terraform {
  backend "s3" {}
}
