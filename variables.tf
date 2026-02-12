# -----------------------------------------------------------------------------
# Required Variables
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Name of the Terraform project. Used in all resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.project_name))
    error_message = "project_name must contain only lowercase letters, numbers, and hyphens, and must start and end with a letter or number."
  }
}

variable "github_repo" {
  description = "GitHub repository in org/repo format."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must be in org/repo format."
  }
}

variable "dev_account_id" {
  description = "AWS Account ID for the DEV target environment."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.dev_account_id))
    error_message = "dev_account_id must be a 12-digit AWS account ID."
  }
}

variable "dev_deployment_role_arn" {
  description = "ARN of the existing IAM role in the DEV account for cross-account deployment."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.dev_deployment_role_arn))
    error_message = "dev_deployment_role_arn must be a valid IAM role ARN."
  }
}

variable "prod_account_id" {
  description = "AWS Account ID for the PROD target environment."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.prod_account_id))
    error_message = "prod_account_id must be a 12-digit AWS account ID."
  }
}

variable "prod_deployment_role_arn" {
  description = "ARN of the existing IAM role in the PROD account for cross-account deployment."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.prod_deployment_role_arn))
    error_message = "prod_deployment_role_arn must be a valid IAM role ARN."
  }
}

# -----------------------------------------------------------------------------
# Optional Variables
# -----------------------------------------------------------------------------

variable "github_branch" {
  description = "Branch to trigger pipeline on push."
  type        = string
  default     = "main"
}

variable "iac_runtime" {
  description = "IaC tool to use: terraform or opentofu. Mutually exclusive per pipeline."
  type        = string
  default     = "terraform"

  validation {
    condition     = contains(["terraform", "opentofu"], var.iac_runtime)
    error_message = "iac_runtime must be either 'terraform' or 'opentofu'."
  }
}

variable "iac_version" {
  description = "Version of Terraform or OpenTofu to install in CodeBuild."
  type        = string
  default     = "latest"
}

variable "codestar_connection_arn" {
  description = "Existing CodeStar Connection ARN. Leave empty to create a new connection."
  type        = string
  default     = ""

  validation {
    condition     = var.codestar_connection_arn == "" || can(regex("^arn:aws:codestar-connections:[a-z0-9-]+:[0-9]{12}:connection/.+$", var.codestar_connection_arn))
    error_message = "codestar_connection_arn must be empty or a valid CodeStar Connection ARN."
  }
}

variable "create_state_bucket" {
  description = "Whether the module creates the S3 state bucket. Set to false to use an existing bucket."
  type        = bool
  default     = true
}

variable "state_bucket" {
  description = "Existing S3 bucket name for Terraform state. Required when create_state_bucket is false."
  type        = string
  default     = ""

  validation {
    condition     = var.state_bucket != "" || var.create_state_bucket
    error_message = "state_bucket must be provided when create_state_bucket is false."
  }
}

variable "state_key_prefix" {
  description = "S3 key prefix for state files. Defaults to project_name."
  type        = string
  default     = ""
}

variable "sns_subscribers" {
  description = "Email addresses for pipeline approval notifications."
  type        = list(string)
  default     = []
}

variable "enable_review_gate" {
  description = "Whether to include the optional review approval stage (Stage 4)."
  type        = bool
  default     = false
}

variable "codebuild_compute_type" {
  description = "CodeBuild compute type for all build projects."
  type        = string
  default     = "BUILD_GENERAL1_SMALL"

  validation {
    condition     = contains(["BUILD_GENERAL1_SMALL", "BUILD_GENERAL1_MEDIUM", "BUILD_GENERAL1_LARGE"], var.codebuild_compute_type)
    error_message = "codebuild_compute_type must be BUILD_GENERAL1_SMALL, BUILD_GENERAL1_MEDIUM, or BUILD_GENERAL1_LARGE."
  }
}

variable "codebuild_image" {
  description = "CodeBuild managed image for all build projects."
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"

  validation {
    condition     = can(regex("^aws/codebuild/", var.codebuild_image))
    error_message = "codebuild_image must be an AWS-managed CodeBuild image (prefix: aws/codebuild/)."
  }
}

variable "checkov_soft_fail" {
  description = "When true, checkov findings do not fail the pipeline. Use during initial adoption only."
  type        = bool
  default     = false
}

variable "codebuild_timeout_minutes" {
  description = "Build timeout in minutes for CodeBuild projects."
  type        = number
  default     = 60

  validation {
    condition     = var.codebuild_timeout_minutes >= 5 && var.codebuild_timeout_minutes <= 480
    error_message = "codebuild_timeout_minutes must be between 5 and 480."
  }
}

variable "logging_bucket" {
  description = "Existing S3 bucket name for access logs. When provided, enables server access logging on state and artifact buckets. Leave empty to disable."
  type        = string
  default     = ""
}

variable "logging_prefix" {
  description = "S3 key prefix for access logs. When empty, defaults to s3-access-logs/<project_name>-<bucket_type>/."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch log group retention in days. For compliance (SOC2, PCI-DSS), set to 365."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch Logs retention value."
  }
}

variable "artifact_retention_days" {
  description = "S3 lifecycle expiry in days for pipeline artifacts."
  type        = number
  default     = 30

  validation {
    condition     = var.artifact_retention_days >= 1 && var.artifact_retention_days <= 365
    error_message = "artifact_retention_days must be between 1 and 365."
  }
}

variable "tags" {
  description = "Additional tags merged with module-managed tags and applied to all resources."
  type        = map(string)
  default     = {}
}
