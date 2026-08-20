# =============================================================================
# modules/data — outputs consumed by the root module and modules/service
#
# NEVER output the password or the CA cert. Both live only inside the
# Secrets Manager secret (and, unavoidably, in Terraform state — treat state
# as a credential store: encrypted bucket, versioned, non-public, gitignored).
# =============================================================================

output "db_endpoint" {
  description = "Aiven MySQL hostname."
  value       = var.aiven_host
}

output "db_port" {
  description = "Aiven MySQL port."
  value       = var.aiven_port
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the DB credential envelope. This is what user-data receives — never the value."
  value       = aws_secretsmanager_secret.db.arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret."
  value       = aws_secretsmanager_secret.db.name
}
