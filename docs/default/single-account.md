# Single-Account Deployment

The Default variant supports single-account deployment where both DEV and PROD environments reside in the same AWS account. Environment isolation is achieved through separate Terraform state keys.

## How It Works

Set `dev_account_id` and `prod_account_id` to the same value, and provide deployment role ARNs from the same account:

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"

  project_name = "my-project"
  github_repo  = "my-org/my-project"

  # Same account for both environments
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/deployment-role"
  prod_account_id          = "111111111111"
  prod_deployment_role_arn = "arn:aws:iam::111111111111:role/deployment-role"
}
```

## Environment Isolation

When both environments share the same account, isolation is provided by Terraform state keys:

- DEV state: `s3://<bucket>/<project>/dev/terraform.tfstate`
- PROD state: `s3://<bucket>/<project>/prod/terraform.tfstate`

The pipeline still runs all 9 stages (including mandatory PROD approval). The CodeBuild service role still assumes the deployment role via `sts:AssumeRole`, maintaining the least-privilege pattern.

## When to Use

- Development or sandbox accounts where cross-account setup is not available
- Small teams where full three-account separation is unnecessary
- Proof-of-concept deployments

## When NOT to Use

- Production workloads that require account-level blast radius isolation
- Regulated environments where DEV and PROD must be in separate accounts
- When different IAM boundaries are needed per environment

## Example

See `examples/default/single-account/` for a runnable configuration.
