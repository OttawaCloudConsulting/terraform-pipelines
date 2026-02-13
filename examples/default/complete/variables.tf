variable "project_name" {
  description = "Name of the Terraform project."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in org/repo format."
  type        = string
}

variable "dev_account_id" {
  description = "AWS Account ID for the DEV target environment."
  type        = string
}

variable "dev_deployment_role_arn" {
  description = "ARN of the existing IAM role in the DEV account."
  type        = string
}

variable "prod_account_id" {
  description = "AWS Account ID for the PROD target environment."
  type        = string
}

variable "prod_deployment_role_arn" {
  description = "ARN of the existing IAM role in the PROD account."
  type        = string
}

variable "codestar_connection_arn" {
  description = "Existing CodeStar Connection ARN."
  type        = string
}

variable "state_bucket" {
  description = "Existing S3 bucket name for Terraform state."
  type        = string
}
