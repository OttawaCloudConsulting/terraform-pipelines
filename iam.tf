# -----------------------------------------------------------------------------
# CodePipeline Service Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "codepipeline" {
  name = "CodePipeline-${var.project_name}-ServiceRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.all_tags
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "CodePipeline-${var.project_name}-Policy"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ArtifactAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      {
        Sid    = "CodeBuildAccess"
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild"
        ]
        Resource = [
          aws_codebuild_project.prebuild.arn,
          aws_codebuild_project.plan.arn,
          aws_codebuild_project.deploy.arn,
          aws_codebuild_project.test.arn
        ]
      },
      {
        Sid    = "CodeStarConnectionAccess"
        Effect = "Allow"
        Action = [
          "codestar-connections:UseConnection"
        ]
        Resource = [
          local.codestar_connection_arn
        ]
      },
      {
        Sid    = "SNSPublish"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = [
          aws_sns_topic.approvals.arn
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CodeBuild Service Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "codebuild" {
  name = "CodeBuild-${var.project_name}-ServiceRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.all_tags
}

resource "aws_iam_role_policy" "codebuild" {
  name = "CodeBuild-${var.project_name}-Policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CrossAccountAssumeRole"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = [
          var.dev_deployment_role_arn,
          var.prod_deployment_role_arn
        ]
      },
      {
        Sid    = "S3StateBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${local.state_bucket_name}",
          "arn:aws:s3:::${local.state_bucket_name}/*"
        ]
      },
      {
        Sid    = "S3ArtifactBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      {
        Sid    = "CloudWatchLogsAccess"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.prebuild.arn}:*",
          "${aws_cloudwatch_log_group.plan.arn}:*",
          "${aws_cloudwatch_log_group.deploy.arn}:*",
          "${aws_cloudwatch_log_group.test.arn}:*"
        ]
      },
      {
        Sid    = "CodeBuildReports"
        Effect = "Allow"
        Action = [
          "codebuild:CreateReportGroup",
          "codebuild:CreateReport",
          "codebuild:UpdateReport",
          "codebuild:BatchPutTestCases",
          "codebuild:BatchPutCodeCoverages"
        ]
        Resource = [
          "arn:aws:codebuild:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:report-group/${var.project_name}-*"
        ]
      }
    ]
  })
}
