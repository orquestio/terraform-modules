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
# Product profile — static per-product values (profiles/<profile>.json).
# Selected by var.profile (passed by the orchestrator's terraform.py when the
# blueprint carries a non-null `profile`; defaults to "openclaw").
# =============================================================================

locals {
  profile = jsondecode(file("${path.module}/profiles/${var.profile}.json"))
}

# =============================================================================
# Password de acceso al producto (generado automáticamente)
# =============================================================================

resource "random_password" "gateway_password" {
  length  = 32
  special = false
}

# =============================================================================
# EBS gp3 — Datos persistentes del producto
# =============================================================================
# Migrado desde EFS One Zone el 2026-05-08. El cache validator de OpenClaw
# (upstream issue #73647, closed-as-not-planned) escribe a /home/node/.openclaw
# en bucle y NFS amplificaba 5-20× la latencia por syscall, llevando al
# container a 100% I/O wait y a resets silenciosos de sesión. EBS gp3
# entrega ~1 ms de latencia y 3000 IOPS baseline, eliminando el cuello.
# Ver runbook: project_management/Resiliencia_OpenClaw_EBS/progreso.md.
#
# El path de mount sigue siendo `/mnt/efs` deliberadamente — todos los
# scripts del módulo y los tests `tests/unit/test_openclaw_*.py` lo
# tratan como path canónico. El nombre es legacy; el filesystem detrás
# ahora es ext4 sobre EBS gp3.

resource "aws_ebs_volume" "data" {
  availability_zone = var.primary_az
  size              = 20
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = true

  tags = {
    Name       = "${var.project}-${var.instance_id}-data"
    Project    = var.project
    InstanceId = var.instance_id
  }
}

resource "aws_volume_attachment" "data" {
  # device_name = "/dev/sdf" es el alias presentado por el block-device
  # mapping API de EC2. En Nitro (t4g.*, m6g.*, etc.) el OS expone el
  # volumen como /dev/nvme1n1 — el user_data detecta ambos. Mantener
  # /dev/sdf por compatibilidad con instancias no-Nitro futuras.
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.client.id

  # Sin force_detach el destroy del attach espera unmount limpio del OS.
  # Con OpenClaw escribiendo, esa espera puede colgarse. force_detach=true
  # equivale a "detach" desde la consola — seguro porque el filesystem
  # está montado read/write y el destroy del módulo implica destroy del
  # EC2 (no es un detach standalone que dejaría datos a medio escribir).
  force_detach = true
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
  # Strip full-line bash comments (except shebang) before base64-encoding
  # to stay within the 16384-byte user_data limit. The template file keeps
  # comments for developer readability; this filter runs at plan time only.
  # Profile-driven: the 5 fixed tfvar-derived values are merged with the
  # product profile's template_vars (profiles/<profile>.json). The openclaw
  # profile reproduces today's literals byte-for-byte (see PRODUCT_PROFILE_CONTRACT.md
  # + the render-diff gate). Additional products add a profile; no fork.
  user_data_base64 = base64encode(
    join("\n", [
      for line in split("\n", templatefile("${path.module}/user_data.sh", merge({
        docker_image     = var.docker_image
        container_port   = var.container_port
        instance_id      = var.instance_id
        gateway_password = random_password.gateway_password.result
        aws_region       = data.aws_region.current.name
      }, local.profile.template_vars))) : line if length(regexall("^\\s*#([^!]|$)", line)) == 0
    ])
  )

  tags = {
    Name       = "${var.project}-${var.instance_id}"
    Project    = var.project
    InstanceId = var.instance_id
    TenantId   = var.tenant_id
  }

  # user_data is a one-shot bootstrap script. Changes to the template should
  # never trigger an instance recreate (that would destroy client data).
  # Without this, terraform evaluates the full rendered user_data on every
  # plan/destroy — and if the rendered output exceeds the 16384 byte limit,
  # terraform aborts with a validation error, blocking destroy entirely.
  lifecycle {
    ignore_changes = [user_data, user_data_base64]
  }
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
# AWS Backup — Snapshots diarios del volumen de datos (EBS)
# =============================================================================

resource "aws_backup_vault" "instance" {
  name = "${var.project}-${var.instance_id}-vault"

  # Recovery points accumulate over time; without force_destroy, terraform
  # destroy aborts with InvalidRequestException when the vault is non-empty
  # and the EC2/EBS/etc end up half-cleaned. force_destroy=true tells the
  # AWS provider to delete every recovery point before the vault itself.
  force_destroy = true

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
  name         = "${var.project}-${var.instance_id}-data"
  plan_id      = aws_backup_plan.instance.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [aws_ebs_volume.data.arn]
}
