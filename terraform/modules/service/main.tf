# =============================================================================
# modules/service — EC2 (Docker-backed) + nginx + SG + ALB
#
# Runs the app image as a Docker-backed EC2 instance, fronts it with nginx, and
# declares the load-balancer topology as IaC.
#
# Boot contract: user-data receives the secret ARN and the DB address only. The
# password is fetched at runtime by api/secrets.js via GetSecretValue, so it
# never exists in user-data, in the image, or in git.
#
# AMI assumption: CI tags the built app image as localstack-ec2/app:ami-<sha12>.
# User-data starts that image in place.
#
# Inputs  -> variables.tf
# Outputs -> outputs.tf  (instance_id, private_ip, security_group_id, alb_dns_name)
# =============================================================================

# -----------------------------------------------------------------------------
# Default VPC / subnets. Looked up instead of hardcoded so LocalStack restarts
# do not leave stale IDs in the config.
# -----------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# -----------------------------------------------------------------------------
# Security group.
#
# Ingress is scoped to the VPC CIDR, never 0.0.0.0/0.
#
# FIDELITY: LocalStack honours only the default SG, and ingress rules are
# evaluated at instance-creation time. Editing a rule after the fact has no
# effect on a running instance — you have to recreate it (failure mode #3 in
# ASSIGNMENT.md). Both caveats are documented in FIDELITY.md.
# -----------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "Ingress to nginx (80) and the app (${var.app_port}) for ${var.project_name}"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP to nginx from inside the VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  ingress {
    description = "Direct app port, for /metrics scraping and incident replay"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # Egress is open so the instance can call Secrets Manager and install nginx.
  egress {
    description = "Outbound for Secrets Manager and package installation"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-app-sg"
  }
}

# -----------------------------------------------------------------------------
# Application instance.
#
# user_data carries the secret ARN, not the secret value.
# trivy:ignore:AVD-AWS-0131 -- dynamic root_block_device omitted for LocalStack (FIDELITY.md §6); encrypted when skip_root_block_device=false
# -----------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = var.app_ami_id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    secret_arn       = var.secret_arn
    db_host          = var.db_host_from_instance
    db_endpoint_raw  = var.db_endpoint
    db_port          = var.db_port
    app_port         = var.app_port
    aws_region       = var.aws_region
    aws_endpoint_url = var.aws_endpoint_url
  })

  # Omit on LocalStack when DescribeImages cannot resolve the Docker-tagged AMI.
  dynamic "root_block_device" {
    for_each = var.skip_root_block_device ? [] : [1]
    content {
      volume_size = var.root_volume_size
      encrypted   = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name = "${var.project_name}-app"
  }
}

# -----------------------------------------------------------------------------
# Load-balancer topology.
#
# nginx carries real traffic on LocalStack. ALB resources are optional IaC for
# the production-shaped topology. Health checks use /readyz, not /healthz.
#
# FIDELITY: LocalStack's ELBv2 health checking is undocumented and the listener
# port round-trips oddly, so the listener pins `port` with ignore_changes to
# stop every subsequent plan showing phantom drift.
# -----------------------------------------------------------------------------
resource "aws_lb" "app" {
  count = var.enable_alb ? 1 : 0

  name                       = "${var.project_name}-alb"
  internal                   = true # lab: ALB is IaC-only; nginx on the instance serves traffic
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.app.id]
  subnets                    = data.aws_subnets.default.ids
  drop_invalid_header_fields = true

  enable_deletion_protection = false # lab: `make destroy` has to run unattended

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  count = var.enable_alb ? 1 : 0

  name        = "${var.project_name}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip" # Docker-backed instances register by IP, not instance id

  health_check {
    path                = var.health_check_path
    port                = "80"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.project_name}-tg"
  }
}

resource "aws_lb_target_group_attachment" "app" {
  count = var.enable_alb ? 1 : 0

  target_group_arn = aws_lb_target_group.app[0].arn
  target_id        = aws_instance.app.private_ip
  port             = 80
}

resource "aws_lb_listener" "http" {
  count = var.enable_alb ? 1 : 0

  load_balancer_arn = aws_lb.app[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[0].arn
  }

  lifecycle {
    # LocalStack echoes the listener port back inconsistently; without this every
    # post-apply plan is non-empty and `make verify` (C8) fails on a phantom diff.
    ignore_changes = [port]
  }
}
