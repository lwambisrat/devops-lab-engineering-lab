# =============================================================================
# modules/data — inputs
# =============================================================================

variable "project_name" {
  description = "Stack prefix, e.g. rh-lwam. Used in the secret description."
  type        = string
}

variable "db_name" {
  description = "Database (schema) name inside your Aiven MySQL service."
  type        = string
  default     = "capacity_lab"
}

variable "secret_name" {
  description = "Secrets Manager secret name holding the DB credential envelope."
  type        = string
  default     = "regional-health/db"
}

# --- Aiven connection details ------------------------------------------------
# From your Aiven service page (aiven.io -> your MySQL service -> Overview).
# These belong in your gitignored <name>.tfvars, never committed, and are
# marked sensitive so `terraform plan`/`apply` never prints them to the
# console or into apply.log.

variable "aiven_host" {
  description = "Aiven MySQL hostname, e.g. mysql-xxxx-lwam.aivencloud.com."
  type        = string
}

variable "aiven_port" {
  description = "Aiven MySQL port (shown on the service Overview page, not the default 3306)."
  type        = number
}

variable "aiven_user" {
  description = "Aiven MySQL username. Default is avnadmin."
  type        = string
  default     = "avnadmin"
}

variable "aiven_password" {
  description = "Aiven MySQL password, from the service Overview page."
  type        = string
  sensitive   = true
}

variable "aiven_ca_cert" {
  description = "Contents of the CA certificate Aiven provides for TLS (paste the whole .pem file as a string). Stored in the secret for when database.js adds TLS support."
  type        = string
  sensitive   = true
}
