# =============================================================================
# modules/data — Secrets Manager for Aiven MySQL
#
# Aiven owns the MySQL service and password. Terraform does not create the DB;
# it stores the connection envelope in LocalStack Secrets Manager so the app can
# resolve credentials at boot without putting secret values in git, the image,
# or user-data.
#
# Inputs  -> variables.tf
# Outputs -> outputs.tf  (db_endpoint, db_port, secret_arn, secret_name)
# =============================================================================

resource "aws_secretsmanager_secret" "db" {
  name        = var.secret_name
  description = "Aiven MySQL credentials for ${var.project_name} (Regional Health capacity lab)."
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  # Envelope keys match api/secrets.js. ca_cert is required because Aiven MySQL
  # requires TLS.
  secret_string = jsonencode({
    engine   = "mysql"
    username = var.aiven_user
    password = var.aiven_password
    host     = var.aiven_host
    port     = var.aiven_port
    dbname   = var.db_name
    ca_cert  = var.aiven_ca_cert
  })
}
