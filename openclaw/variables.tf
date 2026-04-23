variable "instance_id" {
  description = "ID único de la instancia (ej: acme-openclaw-001)"
  type        = string
}

variable "tenant_id" {
  description = "ID del tenant al que pertenece"
  type        = string
}

variable "instance_type" {
  description = "Tipo de EC2 según plan (t4g.small, t4g.medium, t4g.large)"
  type        = string
  default     = "t4g.small"
}

variable "ami_id" {
  description = "AMI base ARM64 con Docker + CW Agent + EFS utils"
  type        = string
}

variable "docker_image" {
  description = "Imagen Docker del producto, pineada a un tag específico del upstream. REQUERIDA sin default: la pin debe venir del blueprint seed (orchestrator/sql/seeds/openclaw.sql) para que haya una única fuente de verdad. NUNCA usar :latest. Ver orchestrator/OPENCLAW_RELEASE_POLICY.md para el procedimiento de bump."
  type        = string
}

variable "container_port" {
  description = "Puerto del contenedor del producto"
  type        = number
  default     = 18789
}

variable "subnet_id" {
  description = "Subnet donde lanzar la instancia"
  type        = string
}

variable "security_group_id" {
  description = "Security Group de instancias de cliente"
  type        = string
}

variable "iam_instance_profile" {
  description = "Instance profile de cliente"
  type        = string
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID de Cloudflare para el dominio del producto"
  type        = string
}

variable "cloudflare_api_token" {
  description = "Token API de Cloudflare"
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "Dominio del producto (ej: orquestio.com)"
  type        = string
  default     = "orquestio.com"
}

variable "backup_retention_days" {
  description = "Días de retención de backups de EFS"
  type        = number
  default     = 7
}

variable "primary_az" {
  description = "AZ para EFS One Zone"
  type        = string
  default     = "us-east-1d"
}

variable "project" {
  description = "Nombre del proyecto (prefijo de recursos)"
  type        = string
  default     = "orquestio"
}
