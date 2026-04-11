output "ec2_instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.client.id
}

output "public_ip" {
  description = "IP pública de la instancia (Elastic IP — estable a través de stop/start)"
  value       = aws_eip.client.public_ip
}

output "eip_allocation_id" {
  description = "ID de allocation del Elastic IP de la instancia"
  value       = aws_eip.client.id
}

output "direct_dns_record_id" {
  description = "ID del registro DNS unproxied -direct (Plan B BYO custom domain target)"
  value       = cloudflare_record.instance_direct.id
}

output "efs_id" {
  description = "ID del filesystem EFS"
  value       = aws_efs_file_system.data.id
}

output "dns_record_id" {
  description = "ID del registro DNS en Cloudflare"
  value       = cloudflare_record.instance.id
}

output "access_url" {
  description = "URL de acceso del cliente"
  value       = "https://${var.instance_id}.${var.domain}"
}

output "access_password" {
  description = "Password de acceso al gateway"
  value       = random_password.gateway_password.result
  sensitive   = true
}

