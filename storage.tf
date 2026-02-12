# -----------------------------------------------------------------------------
# S3 State Bucket (conditional)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = "${var.project_name}-terraform-state"
  tags   = local.all_tags
}

resource "aws_s3_bucket_versioning" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonSSLRequests"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state[0].arn,
          "${aws_s3_bucket.state[0].arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# Data source for existing state bucket
data "aws_s3_bucket" "existing_state" {
  count  = var.create_state_bucket ? 0 : 1
  bucket = var.state_bucket
}

# -----------------------------------------------------------------------------
# S3 Artifact Bucket
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.project_name}-pipeline-artifacts"
  tags   = local.all_tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonSSLRequests"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-artifacts"
    status = "Enabled"

    expiration {
      days = var.artifact_retention_days
    }
  }
}

# -----------------------------------------------------------------------------
# SNS Topic for Approvals
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "approvals" {
  name              = "${var.project_name}-pipeline-approvals"
  kms_master_key_id = "alias/aws/sns"
  tags              = local.all_tags
}

resource "aws_sns_topic_policy" "approvals" {
  arn = aws_sns_topic.approvals.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCodePipelinePublish"
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.approvals.arn
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.sns_subscribers)
  topic_arn = aws_sns_topic.approvals.arn
  protocol  = "email"
  endpoint  = each.value
}
