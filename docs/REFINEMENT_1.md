# Refinement 1: Per-Environment Plan-Apply Pipeline Flow

## Problem Statement

The current pipeline architecture has a structural flaw in how Terraform plans and deploys are handled.

### Current Behavior

The pipeline has a single **Plan** stage that:
- Runs `terraform plan` with **no var file** (`-var-file` is never passed)
- Initializes against a throwaway state path (`<prefix>/plan/terraform.tfstate`), not the real environment state
- Produces a `tfplan` artifact that is **never consumed** by any downstream stage
- Serves only as input for the Checkov security scan and the optional Review gate

The **Deploy** stages then:
- Run their own `terraform init` against the real environment state (`<prefix>/dev/terraform.tfstate` or `<prefix>/prod/terraform.tfstate`)
- Run `terraform apply -auto-approve` directly, generating an implicit plan at apply time
- Conditionally pass `-var-file=environments/${TARGET_ENV}.tfvars`

### Why This Is Wrong

1. **The plan that is reviewed is not the plan that is applied.** The Review gate shows an environment-agnostic plan without tfvars, but the deploy stages apply with environment-specific tfvars against different state. The reviewer approves one thing; a different thing executes.

2. **No saved-plan guarantee.** Terraform best practice is `terraform plan -out=tfplan` followed by `terraform apply tfplan`. This ensures exactly what was reviewed is what gets applied. The current deploy stages re-plan at apply time, meaning infrastructure could have drifted between review and apply.

3. **Environment-agnostic plan is misleading.** Without var files and without real environment state, the plan output may not reflect actual changes. Resources that differ between environments (instance sizes, feature flags, account-specific values) are invisible in the current plan.

## Proposed Pipeline Flow

Each environment is a single consolidated stage with multiple actions ordered by `run_order`. Plan, optional approval, and deploy happen within the same stage. Actions at a higher `run_order` block until all actions at the previous `run_order` complete — a Manual Approval action blocks the Deploy action from executing.

### Default Variant (7 stages)

```
1. Source
2. Pre-Build
3. DEV
   ├── run_order=1: Plan DEV       — terraform plan -var-file=environments/dev.tfvars -out=tfplan
   │                                  + Checkov security scan on plan (optional, default enabled)
   ├── run_order=2: Approve DEV    — optional manual approval (controlled by enable_review_gate)
   └── run_order=3: Deploy DEV     — terraform apply tfplan (saved plan)
4. Test DEV
5. PROD
   ├── run_order=1: Plan PROD      — terraform plan -var-file=environments/prod.tfvars -out=tfplan
   │                                  + Checkov security scan on plan (optional, default enabled)
   ├── run_order=2: Approve PROD   — mandatory manual approval (SNS notification)
   └── run_order=3: Deploy PROD    — terraform apply tfplan (saved plan)
6. Test PROD
```

### Default-DevDestroy Variant (8-9 stages)

```
1. Source
2. Pre-Build
3. DEV
   ├── run_order=1: Plan DEV       — terraform plan -var-file=environments/dev.tfvars -out=tfplan
   │                                  + Checkov security scan on plan (optional, default enabled)
   ├── run_order=2: Approve DEV    — optional manual approval (controlled by enable_review_gate)
   └── run_order=3: Deploy DEV     — terraform apply tfplan (saved plan)
4. Test DEV
5. PROD
   ├── run_order=1: Plan PROD      — terraform plan -var-file=environments/prod.tfvars -out=tfplan
   │                                  + Checkov security scan on plan (optional, default enabled)
   ├── run_order=2: Approve PROD   — mandatory manual approval (SNS notification)
   └── run_order=3: Deploy PROD    — terraform apply tfplan (saved plan)
6. Test PROD
7. Destroy Approval               — optional (controlled by enable_destroy_approval)
8. Destroy DEV                    — terraform destroy against dev state
```

### Key Changes

| Aspect | Current | Proposed |
|--------|---------|----------|
| Plan stages | 1 (environment-agnostic, no tfvars) | Per-environment (action within each env stage) |
| Plan state | Throwaway `plan/terraform.tfstate` | Real environment state (`dev/` or `prod/`) |
| Deploy method | `terraform apply -auto-approve` (re-plans) | `terraform apply tfplan` (saved plan) |
| Plan artifact | Generated but unused | Passed from Plan action to Deploy action within same stage |
| Security scan | Runs on environment-agnostic plan | Runs on real per-environment plan (optional, default enabled) |
| Stage structure | Separate stages for plan, approval, deploy | Consolidated: one stage per environment with ordered actions |
| Review gate (optional) | Separate stage, reviews wrong plan | Approval action within env stage, reviews correct plan |

### Security Scan

The Checkov security scan runs within the Plan action of each environment stage. It scans the `tfplan.json` generated from the real per-environment plan (with tfvars and real state). This means the scan reflects actual intended changes, not an environment-agnostic approximation.

- Controlled by a new variable: `enable_security_scan` (default: `true`)
- When enabled, the Plan buildspec runs Checkov after `terraform plan` and `terraform show -json`
- When disabled, the Plan buildspec skips the Checkov step
- Existing `checkov_soft_fail` variable continues to control hard-fail vs soft-fail behavior

### Artifact Flow

Within each environment stage, the Plan action produces an output artifact consumed by the Deploy action:

```
DEV Stage:
  Plan DEV (run_order=1)  --[dev_plan_output]--> Deploy DEV (run_order=3)

PROD Stage:
  Plan PROD (run_order=1) --[prod_plan_output]--> Deploy PROD (run_order=3)
```

The Deploy action receives the saved `tfplan` file and runs `terraform apply tfplan` — no re-initialization, no re-planning.

### Cross-Account Considerations

Both the Plan and Deploy actions for a given environment must assume the same cross-account role. `terraform plan` needs read access to the target account's resources to compute accurate diffs. The Plan actions will receive `TARGET_ROLE` and `TARGET_ENV` as environment variable overrides from the pipeline action configuration, same as the Deploy actions.

### Variable Changes

| Variable | Change | Description |
|----------|--------|-------------|
| `enable_review_gate` | Repurposed | Controls optional approval action within the DEV stage (PROD approval remains mandatory) |
| `enable_security_scan` | **New** | Controls Checkov scan within each Plan action (default: `true`) |
| `checkov_soft_fail` | Unchanged | Controls Checkov hard-fail vs soft-fail behavior |

### Buildspec Changes Required

- **`plan.yml`** — Must accept `TARGET_ENV` and `TARGET_ROLE`. Assume cross-account role, init against real environment state (`<prefix>/${TARGET_ENV}/terraform.tfstate`), pass `-var-file=environments/${TARGET_ENV}.tfvars` (if exists), run Checkov on plan (if `ENABLE_SECURITY_SCAN=true`), output saved `tfplan` as artifact.
- **`deploy.yml`** — Must consume plan artifact and run `terraform apply tfplan` instead of re-initializing and re-planning. Still needs cross-account role assumption for the apply.
- **Current standalone Plan stage and buildspec** — Removed. Plan is now an action within each environment stage.
