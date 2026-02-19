# Default-DevDestroy Variant

Extends the Default variant with a DEV teardown stage. After PROD smoke tests pass, the pipeline optionally requests approval and then runs `terraform destroy` against the DEV environment.

## Pipeline Stages

| # | Stage | Type | Description |
|---|-------|------|-------------|
| 1 | Source | CodeStar | GitHub via CodeStar Connection |
| 2 | Pre-Build | CodeBuild | Runs `cicd/prebuild/main.sh` |
| 3 | Plan | CodeBuild | `terraform plan` + checkov scan |
| 4 | Review | Manual Approval | Optional (`enable_review_gate = true`) |
| 5 | Deploy DEV | CodeBuild | `terraform apply` to DEV |
| 6 | Test DEV | CodeBuild | Runs `cicd/dev/smoke-test.sh` |
| 7 | Approval | Manual Approval | Mandatory PROD approval |
| 8 | Deploy PROD | CodeBuild | `terraform apply` to PROD |
| 9 | Test PROD | CodeBuild | Runs `cicd/prod/smoke-test.sh` |
| 10 | Destroy Approval | Manual Approval | **Optional** (`enable_destroy_approval = true`, the default) |
| 10/11 | Destroy DEV | CodeBuild | `terraform destroy` against DEV |

## Usage

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default-dev-destroy"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/deployment-role"
  prod_account_id          = "222222222222"
  prod_deployment_role_arn = "arn:aws:iam::222222222222:role/deployment-role"

  # Safe by default — manual approval before destroy
  enable_destroy_approval = true
}
```

## Destroy Approval Gate

The `enable_destroy_approval` variable controls whether a manual approval stage is inserted before the destroy:

| Value | Stages | Behavior |
|-------|--------|----------|
| `true` (default) | 11 | Manual approval required before DEV destroy |
| `false` | 10 | Destroy runs automatically after PROD tests pass |

The approval gate uses the same SNS topic as the mandatory PROD approval, so the same subscribers are notified.

## Destroy Stage Details

- **CodeBuild project:** `<project_name>-destroy` (variant-owned, not in core module)
- **Buildspec:** `modules/default-dev-destroy/buildspecs/destroy.yml`
- **Service role:** Same CodeBuild service role from core (no privilege escalation)
- **Credential flow:** `sts:AssumeRole` to DEV deployment role (same as deploy stage)
- **Command:** `terraform init` + `terraform destroy -auto-approve`
- **Var-file:** Checks for `environments/dev.tfvars` (graceful skip if missing)

## Failure Behavior

If the destroy stage fails:
- The pipeline execution shows as **Failed** in CodePipeline
- The DEV environment remains intact (no partial destruction)
- The PROD environment is unaffected (it was already deployed and tested)

## Additional Resources

This variant creates 2 additional resources beyond what the Default variant creates:

| Resource | Name | Description |
|----------|------|-------------|
| `aws_codebuild_project` | `<project>-destroy` | Runs terraform destroy |
| `aws_cloudwatch_log_group` | `/codebuild/<project>-destroy` | Destroy build logs |

These resources are registered with core IAM policies via `additional_codebuild_project_arns` and `additional_log_group_arns`.

## When to Use

- Ephemeral DEV environments that should be torn down after each deployment cycle
- Cost optimization — avoid leaving DEV infrastructure running between deployments
- Testing infrastructure-as-code destroy paths as part of the CI/CD lifecycle

## Example

See `examples/default-dev-destroy/minimal/` for a runnable configuration.
