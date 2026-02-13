variable "project_name" {
  description = "Name of the Terraform project."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in org/repo format."
  type        = string
}

variable "account_id" {
  description = "AWS Account ID used for both DEV and PROD (single-account deployment)."
  type        = string
}

variable "deployment_role_arn" {
  description = "ARN of the existing IAM role for deployment (used for both environments)."
  type        = string
}
