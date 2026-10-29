output "aws_region" {
  description = "Region where the demo resources were created."
  value       = var.aws_region
}

output "vpc_id" {
  description = "Demo VPC."
  value       = aws_vpc.main.id
}

output "private_subnet_id" {
  description = "Subnet that contains the backend instance."
  value       = aws_subnet.private.id
}

output "instance_id" {
  description = "Private EC2 instance ID. Use it with SSM Session Manager."
  value       = aws_instance.backend.id
}

output "instance_private_ip" {
  description = "Private IP of the backend instance. It is not reachable from the public internet."
  value       = aws_instance.backend.private_ip
}

output "instance_public_ip" {
  description = "Public IP of the backend instance. This is empty because the instance is not assigned one."
  value       = aws_instance.backend.public_ip
}

output "security_group_id" {
  description = "Security group with no inbound rules."
  value       = aws_security_group.backend.id
}

output "artifact_bucket" {
  description = "Private bucket used to copy the backend bundle onto the instance."
  value       = aws_s3_bucket.artifacts.bucket
}

output "secret_arns" {
  description = "Secrets Manager ARNs. Terraform stores the ARNs, not the secret values."
  value = {
    supabase_url              = aws_secretsmanager_secret.supabase_url.arn
    supabase_publishable_key  = aws_secretsmanager_secret.supabase_publishable_key.arn
    supabase_internal_api_key = aws_secretsmanager_secret.supabase_internal_api_key.arn
    backend_auth_token        = aws_secretsmanager_secret.backend_auth_token.arn
    cloudflare_tunnel_token   = aws_secretsmanager_secret.cloudflare_tunnel_token.arn
  }
}

output "ssm_session_command" {
  description = "Command that opens a shell on the private instance without SSH."
  value       = "aws ssm start-session --target ${aws_instance.backend.id} --region ${var.aws_region}"
}
