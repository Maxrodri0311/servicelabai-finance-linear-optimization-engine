# ==============================================================================
# Servicelab AI - Terraform Variables Specification
# ==============================================================================

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Primary AWS target region for data lakehouse and RDS deployment."
}

variable "environment" {
  type        = string
  default     = "production"
  description = "Target environment stage (development, staging, production)."

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "Environment must be one of: development, staging, production."
  }
}

variable "vpc_cidr" {
  type        = string
  default     = "10.120.0.0/16"
  description = "CIDR block allocated for the Servicelab AI analytics VPC."
}

variable "db_instance_class" {
  type        = string
  default     = "db.r6g.xlarge"
  description = "AWS RDS database instance family (Graviton3 memory-optimized)."
}

variable "allocated_storage_gb" {
  type        = number
  default     = 100
  description = "Initial SSD storage provisioned for analytical telemetry store."

  validation {
    condition     = var.allocated_storage_gb >= 50 && var.allocated_storage_gb <= 1000
    error_message = "Allocated storage must be between 50 GB and 1000 GB."
  }
}

variable "max_allocated_storage_gb" {
  type        = number
  default     = 500
  description = "Upper threshold limit for automated database storage autoscaling."
}

variable "db_master_username" {
  type        = string
  default     = "servicelabai_admin"
  description = "Master administrative user name for PostgreSQL 16 cluster."
}

variable "db_master_password" {
  type        = string
  default     = "SrvLab2026_SecureTelemetryCluster#X9"
  sensitive   = true
  description = "Master password for PostgreSQL database instance."
}
