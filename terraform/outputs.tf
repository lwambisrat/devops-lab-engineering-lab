# =============================================================================
# terraform/outputs.tf  (root)
# -----------------------------------------------------------------------------
# These are what `make verify` (Step 3) and the evidence-capture steps will
# read. Never add the DB password here — see modules/data/outputs.tf, it's
# not exposed at the module level either, so there's nothing to leak even by
# accident.
# =============================================================================

output "db_endpoint" {
  description = "Aiven MySQL hostname stored in Secrets Manager."
  value       = module.data.db_endpoint
}

output "db_port" {
  value = module.data.db_port
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret. This is what evidence/03-secrets/user-data.txt should show being passed to the instance."
  value       = module.data.secret_arn
}

output "instance_id" {
  description = "EC2 instance id for the app tier."
  value       = module.service.instance_id
}

output "app_url" {
  description = "Base URL for smoke checks — append /healthz, /readyz, or /metrics. `make verify` (C8) reads this."
  value       = module.service.app_url
}

output "security_group_id" {
  description = "App security group id. Worth capturing in evidence: on LocalStack an SG rule change only takes effect when the instance is recreated."
  value       = module.service.security_group_id
}
