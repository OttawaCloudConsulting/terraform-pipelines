variable "github_repo" {
  description = "GitHub repository in org/repo format"
  type        = string
}

variable "github_branch" {
  description = "GitHub branch to trigger pipeline"
  type        = string
  default     = "main"
}

variable "dev_account_id" {
  description = "12-digit AWS Account ID for the DEV target account"
  type        = string
}

variable "dev_deployment_role_arn" {
  description = "IAM role ARN in the DEV target account for cross-account deployment"
  type        = string
}

variable "prod_account_id" {
  description = "12-digit AWS Account ID for the PROD target account"
  type        = string
}

variable "prod_deployment_role_arn" {
  description = "IAM role ARN in the PROD target account for cross-account deployment"
  type        = string
}
