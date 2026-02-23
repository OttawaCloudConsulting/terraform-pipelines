variable "project_name" {
  description = "Name of the Terraform project."
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
