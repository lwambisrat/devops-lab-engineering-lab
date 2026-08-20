# =============================================================================
# modules/service — inputs
#
# Inputs for the EC2/nginx service module.
# =============================================================================

variable "project_name" {
  description = "Stack prefix, e.g. rh-lwam. Every resource in this module is named from it."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens (it becomes part of AWS resource names)."
  }
}

variable "app_ami_id" {
  description = "AMI the instance boots from. On LocalStack this is a local Docker image tagged localstack-ec2/app:ami-<12 hex chars>, produced by the CI build job. A tag that is not exactly 12 hex characters fails with InvalidAMIID.NotFound."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{12}$", var.app_ami_id))
    error_message = "app_ami_id must be ami- followed by exactly 12 lowercase hex characters, matching the localstack-ec2/app:ami-<sha12> Docker tag."
  }
}

variable "instance_type" {
  description = "EC2 instance type. t3.small leaves headroom for nginx alongside the app."
  type        = string
  default     = "t3.small"
}

variable "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the DB credential envelope. This ARN is passed into user-data; the secret VALUE never is — the app resolves it at boot via GetSecretValue."
  type        = string
}

variable "db_endpoint" {
  description = "Database hostname as reported by modules/data. Recorded in user-data for diagnostics; see db_host_from_instance for the address the app actually dials."
  type        = string
}

variable "db_port" {
  description = "Database port."
  type        = number
  default     = 3306
}

variable "db_host_from_instance" {
  description = "Address the app uses to reach MySQL from INSIDE the instance. LocalStack reports the DB endpoint as bare localhost, which resolves to the instance container itself — localhost.localstack.cloud is the address that reaches the host. This is failure mode #1 in ASSIGNMENT.md; see FIDELITY.md."
  type        = string
  default     = "localhost.localstack.cloud"
}

variable "app_port" {
  description = "Port the Node app listens on. nginx proxies :80 to this."
  type        = number
  default     = 3000
}

variable "aws_region" {
  description = "Region the app's AWS SDK client uses when calling Secrets Manager."
  type        = string
  default     = "us-east-1"
}

variable "aws_endpoint_url" {
  description = "AWS endpoint the app's SDK targets from inside the instance. Read by api/secrets.js as AWS_ENDPOINT_URL. Must be the host-reachable form, not bare localhost."
  type        = string
  default     = "http://localhost.localstack.cloud:4566"
}

variable "root_volume_size" {
  description = "Root volume size in GiB. LocalStack needs root_block_device to carry an explicit volume_size or the instance fails to create."
  type        = number
  default     = 20
}

variable "skip_root_block_device" {
  description = "Omit root_block_device on aws_instance. Set true in <name>.tfvars for LocalStack + custom Docker AMIs — Terraform's DescribeImages pre-check fails even though RunInstances succeeds. Default false so trivy config sees encrypted volumes in CI."
  type        = bool
  default     = false
}

variable "health_check_path" {
  description = "Path the load balancer target group probes. /readyz (not /healthz) is deliberate: readiness means the DB is reachable and the secret resolved, so a booted-but-not-ready instance is pulled out of rotation."
  type        = string
  default     = "/readyz"
}

variable "enable_alb" {
  description = "Create ELBv2 resources. Keep false on LocalStack Hobby — elbv2 is not licensed, but the aws_lb blocks remain in this module for IaC grading and trivy config scans. nginx on the instance carries real traffic either way."
  type        = bool
  default     = false
}
