# =============================================================================
# terraform/variables.tf  (root)
# -----------------------------------------------------------------------------
# Copy terraform/environments/lwam.tfvars.example to terraform/lwam.tfvars and
# fill in local values there. Real tfvars files are gitignored.
# =============================================================================

variable "aws_region" {
  description = "Region to deploy into. Same for everyone on this lab."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Stack prefix, e.g. rh-lwam. Drives resource naming."
  type        = string
}

# --- passed straight through to modules/data --------------------------------
# Aiven MySQL is provisioned outside Terraform. Terraform stores its connection
# details in LocalStack Secrets Manager.

variable "db_name" {
  description = "Database (schema) name inside your Aiven MySQL service."
  type        = string
  default     = "capacity_lab"
}

variable "secret_name" {
  description = "Secrets Manager secret name, e.g. regional-health/lwam/db."
  type        = string
}

variable "aiven_host" {
  description = "Aiven MySQL hostname, from your Aiven service Overview page."
  type        = string
}

variable "aiven_port" {
  description = "Aiven MySQL port, from your Aiven service Overview page."
  type        = number
}

variable "aiven_user" {
  description = "Aiven MySQL username. Default is avnadmin."
  type        = string
  default     = "avnadmin"
}

variable "aiven_password" {
  description = "Aiven MySQL password, from your Aiven service Overview page."
  type        = string
  sensitive   = true
}

variable "aiven_ca_cert" {
  description = "Contents of Aiven's CA certificate .pem file, pasted as a string."
  type        = string
  sensitive   = true
}

# --- passed straight through to modules/service -----------------------------

variable "instance_type" {
  description = "EC2 instance type running the app."
  type        = string
  default     = "t3.small"
}

variable "app_ami_id" {
  description = "AMI tag CI produced, form localstack-ec2/app:ami-<sha12>. No default on purpose — you must supply this deliberately, it changes on every image rebuild."
  type        = string
}

variable "skip_root_block_device" {
  description = "Omit root_block_device for LocalStack Docker-tagged AMIs when DescribeImages cannot resolve them."
  type        = bool
  default     = true
}

variable "enable_alb" {
  description = "Create ELBv2 resources. Keep false on LocalStack Hobby; nginx on the instance carries real traffic."
  type        = bool
  default     = false
}
