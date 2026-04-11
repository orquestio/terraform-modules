terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# =============================================================================
# Password de acceso al producto (generado automáticamente)
# =============================================================================

resource "random_password" "gateway_password" {
  length  = 32
  special = false
}

# =============================================================================
# EFS One Zone — Datos persistentes del producto
# =============================================================================

resource "aws_efs_file_system" "data" {
  availability_zone_name = var.primary_az
  encrypted              = true

  tags = {
    Name       = "${var.project}-${var.instance_id}-efs"
    Project    = var.project
    InstanceId = var.instance_id
  }
}

resource "aws_efs_mount_target" "data" {
  file_system_id  = aws_efs_file_system.data.id
  subnet_id       = var.subnet_id
  security_groups = [var.security_group_id]
}

# =============================================================================
# EC2 — Instancia del cliente
# =============================================================================

resource "aws_instance" "client" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = var.iam_instance_profile
  key_name               = var.key_name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  # user_data.sh fetches upgrade.sh from SSM Parameter Store at boot
  # (/orquestio/prod/OPENCLAW_UPGRADE_SCRIPT_B64, gzip+base64 encoded).
  # Inline embedding was abandoned in Sprint 2.2 retry because the EC2
  # user_data limit is ~12 KB of plaintext and embedding upgrade.sh blew it.
  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    efs_id             = aws_efs_file_system.data.id
    efs_mount_ip       = aws_efs_mount_target.data.ip_address
    docker_image       = var.docker_image
    container_port     = var.container_port
    instance_id        = var.instance_id
    gateway_password   = random_password.gateway_password.result
    aws_region         = data.aws_region.current.name
  }))

  tags = {
    Name       = "${var.project}-${var.instance_id}"
    Project    = var.project
    InstanceId = var.instance_id
    TenantId   = var.tenant_id
  }

  depends_on = [aws_efs_mount_target.data]
}

data "aws_region" "current" {}

# =============================================================================
# Elastic IP — Plan B BYO custom domain
# =============================================================================
# Each customer EC2 gets a dedicated EIP so the customer can point their own
# domain (CNAME or A record) at a stable IP that survives stop/start of the
# instance. The EIP is associated via a separate resource so terraform can
# recreate the EC2 without dropping the EIP and forcing the customer to
# update their DNS. The EIP is automatically released when the module is
# destroyed (terraform destroy frees both resources).

resource "aws_eip" "client" {
  domain = "vpc"

  tags = {
    Name       = "${var.project}-${var.instance_id}-eip"
    Project    = var.project
    InstanceId = var.instance_id
  }
}

resource "aws_eip_association" "client" {
  instance_id   = aws_instance.client.id
  allocation_id = aws_eip.client.id
}

# =============================================================================
# DNS en Cloudflare — {instance_id}.{domain} (proxied) + -direct (unproxied)
# =============================================================================
# Two records:
#   - {instance_id}.orquestio.com (proxied=true): the canonical internal
#     subdomain, behind Cloudflare WAF/DDoS. Used by the gateway login,
#     orchestrator health checks, and the cookie-auth flow.
#   - {instance_id}-direct.orquestio.com (proxied=false): unproxied A record
#     pointing straight at the EIP. Used by Plan B BYO custom domain — the
#     customer creates a CNAME from their domain to this `-direct` hostname,
#     which lets Let's Encrypt HTTP-01 reach the customer EC2 directly
#     without Cloudflare's edge in the middle (CF rejects ACME challenges
#     for hostnames not in its zone).

resource "cloudflare_record" "instance" {
  zone_id = var.cloudflare_zone_id
  name    = var.instance_id
  content = aws_eip.client.public_ip
  type    = "A"
  proxied = true
  ttl     = 1

  comment = "Managed by Terraform - ${var.project}/${var.instance_id}"
}

resource "cloudflare_record" "instance_direct" {
  zone_id = var.cloudflare_zone_id
  name    = "${var.instance_id}-direct"
  content = aws_eip.client.public_ip
  type    = "A"
  proxied = false
  ttl     = 1

  comment = "Managed by Terraform - ${var.project}/${var.instance_id} (BYO custom domain target)"
}

# =============================================================================
# AWS Backup — Snapshots diarios de EFS
# =============================================================================

resource "aws_backup_vault" "instance" {
  name = "${var.project}-${var.instance_id}-vault"

  tags = {
    Project    = var.project
    InstanceId = var.instance_id
  }
}

resource "aws_backup_plan" "instance" {
  name = "${var.project}-${var.instance_id}-plan"

  rule {
    rule_name         = "daily-backup"
    target_vault_name = aws_backup_vault.instance.name
    schedule          = "cron(0 3 * * ? *)"

    lifecycle {
      delete_after = var.backup_retention_days
    }
  }

  tags = {
    Project    = var.project
    InstanceId = var.instance_id
  }
}

resource "aws_iam_role" "backup" {
  name = "${var.project}-${var.instance_id}-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })

  tags = {
    Project    = var.project
    InstanceId = var.instance_id
  }
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restores" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_selection" "instance" {
  name         = "${var.project}-${var.instance_id}-efs"
  plan_id      = aws_backup_plan.instance.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [aws_efs_file_system.data.arn]
}
