variable "aws_region" {
  description = "Region for the private demo network."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Availability zone for the public NAT subnet and the private instance subnet."
  type        = string
  default     = "us-east-1a"
}

variable "name_prefix" {
  description = "Prefix for demo resource names. Lowercase letters, numbers, and hyphens only."
  type        = string
  default     = "supabase-secure-api-demo"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.name_prefix)) && length(var.name_prefix) <= 32
    error_message = "name_prefix must be 1-32 characters of lowercase letters, numbers, and hyphens."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the demo VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "instance_type" {
  description = "Private EC2 size. The instance has no public IP."
  type        = string
  default     = "t3.small"
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window. Zero lets terraform destroy delete the empty secret shells immediately."
  type        = number
  default     = 0

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "Use 0 for immediate demo teardown, or 7-30 days."
  }
}
