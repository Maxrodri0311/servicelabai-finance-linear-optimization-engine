# ==============================================================================
# Servicelab AI - Cloud Infrastructure & Lakehouse Provisioning (Terraform)
# Target: AWS Enterprise Multi-AZ Architecture (S3 Lakehouse, RDS PostgreSQL 16)
# Security: Zero-Trust, AES-256 Server-Side Encryption, KMS Key Rotation, IAM Least Privilege
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = "servicelabai-finance-linear-optimization-engine"
      ManagedBy   = "Terraform"
      Owner       = "Data Science & MLOps Infrastructure"
    }
  }
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# ------------------------------------------------------------------------------
# 1. Enterprise S3 Analytical Lakehouse (AES-256, Lifecycle, Glacier)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "telemetry_lakehouse" {
  bucket        = "servicelabai-sla-telemetry-${var.environment}-${random_id.bucket_suffix.hex}"
  force_destroy = var.environment != "production"
}

resource "aws_s3_bucket_versioning" "lakehouse_versioning" {
  bucket = aws_s3_bucket.telemetry_lakehouse.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lakehouse_encryption" {
  bucket = aws_s3_bucket.telemetry_lakehouse.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "lakehouse_public_block" {
  bucket = aws_s3_bucket.telemetry_lakehouse.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "lakehouse_lifecycle" {
  bucket = aws_s3_bucket.telemetry_lakehouse.id

  rule {
    id     = "archive-aged-incident-telemetry"
    status = "Enabled"

    filter {
      prefix = "raw-incidents/"
    }

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    expiration {
      days = 1095 # 3 Years Retention SLA
    }
  }
}

# ------------------------------------------------------------------------------
# 2. Virtual Private Cloud (VPC) & Dedicated Subnets
# ------------------------------------------------------------------------------
resource "aws_vpc" "analytics_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "servicelabai-analytics-vpc-${var.environment}"
  }
}

resource "aws_subnet" "db_subnet_1" {
  vpc_id            = aws_vpc.analytics_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 1)
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "servicelabai-db-subnet-1-${var.environment}"
  }
}

resource "aws_subnet" "db_subnet_2" {
  vpc_id            = aws_vpc.analytics_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 2)
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "servicelabai-db-subnet-2-${var.environment}"
  }
}

resource "aws_db_subnet_group" "analytics_db_subnet_group" {
  name       = "servicelabai-db-subnet-group-${var.environment}"
  subnet_ids = [aws_subnet.db_subnet_1.id, aws_subnet.db_subnet_2.id]

  tags = {
    Name = "Servicelab AI Analytical DB Subnet Group"
  }
}

# ------------------------------------------------------------------------------
# 3. Security Groups
# ------------------------------------------------------------------------------
resource "aws_security_group" "rds_sg" {
  name        = "servicelabai-rds-security-group-${var.environment}"
  description = "Allows ingress from VPC microservices to PostgreSQL RDS"
  vpc_id      = aws_vpc.analytics_vpc.id

  ingress {
    description = "PostgreSQL secure port"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "servicelabai-rds-sg-${var.environment}"
  }
}

# ------------------------------------------------------------------------------
# 4. Amazon RDS PostgreSQL 16 Multi-AZ Instance
# ------------------------------------------------------------------------------
resource "aws_db_parameter_group" "pg16_custom_params" {
  name   = "servicelabai-pg16-custom-params-${var.environment}"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "work_mem"
    value = "65536" # 64MB for high-throughput window queries
  }

  parameter {
    name  = "maintenance_work_mem"
    value = "524288" # 512MB for index creation
  }

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }
}

resource "aws_db_instance" "analytics_postgres" {
  identifier     = "servicelabai-analytics-db-${var.environment}"
  engine         = "postgres"
  engine_version = "16.2"
  instance_class = var.db_instance_class

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb # Autoscaling storage
  storage_type          = "gp3"
  storage_encrypted     = true

  multi_az               = var.environment == "production"
  db_subnet_group_name   = aws_db_subnet_group.analytics_db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  parameter_group_name   = aws_db_parameter_group.pg16_custom_params.name

  db_name  = "servicelabai_telemetry"
  username = var.db_master_username
  password = var.db_master_password

  backup_retention_period = 14
  backup_window           = "03:00-04:00"
  maintenance_window      = "Sun:04:30-Sun:05:30"

  skip_final_snapshot = var.environment != "production"
  deletion_protection = var.environment == "production"

  tags = {
    Name = "Servicelab AI Analytical Telemetry Store"
  }
}

# ------------------------------------------------------------------------------
# 5. IAM Least-Privilege Role for Analytical Ingestion Service
# ------------------------------------------------------------------------------
resource "aws_iam_role" "ingestion_worker_role" {
  name = "servicelabai-ingestion-worker-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "s3_lakehouse_access_policy" {
  name        = "servicelabai-s3-lakehouse-policy-${var.environment}"
  description = "Allows write and read permissions strictly to the telemetry Lakehouse bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.telemetry_lakehouse.arn,
          "${aws_s3_bucket.telemetry_lakehouse.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_s3_policy" {
  role       = aws_iam_role.ingestion_worker_role.name
  policy_arn = aws_iam_policy.s3_lakehouse_access_policy.arn
}

# ------------------------------------------------------------------------------
# 6. CloudWatch Metric Alarm (SLA Breach Liability Surge)
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "sla_penalty_surge_alarm" {
  alarm_name          = "servicelabai-sla-penalty-surge-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ResidualPenaltyExposureUSD"
  namespace           = "ServicelabAI/OperationalSLA"
  period              = 300
  statistic           = "Average"
  threshold           = 50000.0 # Alert when residual breach risk exceeds $50k/window
  alarm_description   = "Triggers when linear optimization detects critical SLA breach penalty exposure surge."

  tags = {
    Severity = "Critical"
  }
}