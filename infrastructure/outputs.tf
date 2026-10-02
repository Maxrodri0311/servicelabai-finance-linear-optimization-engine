# ==============================================================================
# Servicelab AI - Terraform Outputs Specification
# ==============================================================================

output "telemetry_lakehouse_bucket_name" {
  value       = aws_s3_bucket.telemetry_lakehouse.id
  description = "Canonical Amazon S3 bucket name for raw incident and survival telemetry."
}

output "telemetry_lakehouse_bucket_arn" {
  value       = aws_s3_bucket.telemetry_lakehouse.arn
  description = "Amazon Resource Name (ARN) of the telemetry lakehouse S3 bucket."
}

output "rds_endpoint" {
  value       = aws_db_instance.analytics_postgres.endpoint
  description = "Connection endpoint for the Amazon RDS PostgreSQL 16 instance."
}

output "rds_database_name" {
  value       = aws_db_instance.analytics_postgres.db_name
  description = "Default database name provisioned on the PostgreSQL 16 cluster."
}

output "ingestion_worker_role_arn" {
  value       = aws_iam_role.ingestion_worker_role.arn
  description = "IAM Role ARN to attach to ingestion workers and Lambda dispatchers."
}

output "sla_surge_alarm_arn" {
  value       = aws_cloudwatch_metric_alarm.sla_penalty_surge_alarm.arn
  description = "CloudWatch Alarm ARN monitoring SLA breach financial exposure surges."
}