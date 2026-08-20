# =============================================================================
# terraform/main.tf  (root)
# -----------------------------------------------------------------------------
# Composes the data and service modules for this individual deploy. Resource
# blocks live inside modules; the root only wires inputs and outputs together.
# =============================================================================

module "data" {
  source = "./modules/data"

  project_name   = var.project_name
  db_name        = var.db_name
  secret_name    = var.secret_name
  aiven_host     = var.aiven_host
  aiven_port     = var.aiven_port
  aiven_user     = var.aiven_user
  aiven_password = var.aiven_password
  aiven_ca_cert  = var.aiven_ca_cert
}

# -----------------------------------------------------------------------------
# Service tier. Resource names are derived from project_name so this deploy can
# coexist with other stacks.
# -----------------------------------------------------------------------------
module "service" {
  source = "./modules/service"

  project_name  = var.project_name
  secret_arn    = module.data.secret_arn
  db_endpoint   = module.data.db_endpoint
  db_port       = module.data.db_port
  app_ami_id    = var.app_ami_id
  instance_type = var.instance_type
  aws_region    = var.aws_region

  skip_root_block_device = var.skip_root_block_device
  enable_alb             = var.enable_alb
}
