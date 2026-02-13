# Architecture and Design: Multi-Variant Terraform Pipeline Repository

## Overview

This repository provides a family of reusable Terraform modules that provision AWS CodePipeline V2 + CodeBuild CI/CD pipelines for deploying Terraform (or OpenTofu) infrastructure. Each variant serves a distinct deployment pattern while sharing a common core of infrastructure resources.

The authoritative requirements are in `prd.md`. The original MVP scope is defined in `docs/shared/codepipeline-mvp-statement.md`.

### Variant Summary

| Variant | Module Source | Stages | Account Model | Use Case |
|---------|-------------|--------|---------------|----------|
| **Default** | `modules/default/` | 9 | 3 accounts (Automation + DEV + PROD) | Standard cross-account deployment. Also supports single-account when `dev_account_id == prod_account_id`. |
| **Default-DevDestroy** | `modules/default-dev-destroy/` | 10–11 | 3 accounts (Automation + DEV + PROD) | Cross-account with ephemeral DEV |

## Module Architecture

### Shared Core + Overlay Pattern

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Consumer Root Module                         │
│                                                                     │
│   module "pipeline" {                                               │
│     source = "modules/<variant>"   # default | default-dev-destroy   │
│     ...                                                             │
│   }                                                                 │
└───────────┬─────────────────────────────────┬──────────────────────┘
            │                                 │
            ▼                                 ▼
┌───────────────────────┐    ┌────────────────────────────────────────┐
│   Variant Wrapper     │    │   Variant Wrapper creates:             │
│   (e.g. default/)     │    │   - CodePipeline V2 (stage config)    │
│                       │    │   - Variant-specific resources         │
│   Calls core module   │    │     (e.g. destroy CodeBuild project)  │
└───────────┬───────────┘    └────────────────────────────────────────┘
            │
            ▼
┌───────────────────────────────────────────────────────────────────────┐
│                     Core Module (modules/core/)                       │
│                     Internal only — never called directly             │
│                                                                       │
│   Creates:                                                            │
│   - 2 IAM Roles + Policies (CodePipeline SR, CodeBuild SR)          │
│   - S3 State Bucket (conditional) + Artifact Bucket                  │
│   - SNS Approval Topic + Email Subscriptions                         │
│   - CodeStar Connection (conditional)                                 │
│   - 4 CloudWatch Log Groups (prebuild, plan, deploy, test)           │
│   - 4 CodeBuild Projects (prebuild, plan, deploy, test)              │
│                                                                       │
│   Outputs:                                                            │
│   - All resource ARNs, names, and IDs for variant wiring             │
└───────────────────────────────────────────────────────────────────────┘
```

### Resource Ownership

| Resource | Owner | Notes |
|----------|-------|-------|
| IAM Roles + Policies (x2) | Core | CodePipeline SR + CodeBuild SR |
| S3 State Bucket (conditional) | Core | Shared state storage |
| S3 Artifact Bucket | Core | Pipeline artifacts |
| SNS Approval Topic | Core | Approval notifications |
| CodeStar Connection (conditional) | Core | GitHub integration |
| CloudWatch Log Groups (x4) | Core | prebuild, plan, deploy, test |
| CodeBuild Projects (x4) | Core | prebuild, plan, deploy, test |
| CodePipeline V2 | Variant | Stage definitions are variant-specific |
| Destroy CodeBuild Project | Variant (default-dev-destroy only) | 5th CodeBuild project + log group |
| Destroy Buildspec | Variant (default-dev-destroy only) | `buildspecs/destroy.yml` |

### Core Module Outputs

The core module exposes a comprehensive set of outputs for variant wrappers:

| Output | Type | Purpose |
|--------|------|---------|
| `codebuild_project_names` | `map(string)` | CodeBuild project names for pipeline stage actions |
| `codebuild_service_role_arn` | `string` | For variant-created CodeBuild projects (destroy) |
| `codepipeline_service_role_arn` | `string` | For CodePipeline resource |
| `artifact_bucket_name` | `string` | For CodePipeline artifact store |
| `state_bucket_name` | `string` | Pass-through to consumer |
| `sns_topic_arn` | `string` | For approval stage actions |
| `codestar_connection_arn` | `string` | For source stage action |
| `log_group_arns` | `map(string)` | Log group ARNs for reference |

## Variant Architectures

### Default Variant (9 Stages)

Identical to the original monolithic module. Three-account model with cross-account role assumption.

```
Source → Pre-Build → Plan+Scan → [Optional Review] → Deploy DEV → Test DEV → Mandatory Approval → Deploy PROD → Test PROD
```

**Account model:**
- Automation Account: Pipeline, CodeBuild, S3, SNS, IAM
- DEV Account: Deployment role (pre-existing), target infrastructure
- PROD Account: Deployment role (pre-existing), target infrastructure

**Cross-account credential flow:**
CodeBuild SR → `sts:AssumeRole` (first-hop) → Target account deployment role

### Default-DevDestroy Variant (10–11 Stages)

Extends Default with a DEV teardown stage after PROD tests pass. Optionally includes a manual approval gate before the destroy.

```
Source → Pre-Build → Plan+Scan → [Optional Review] → Deploy DEV → Test DEV → Mandatory Approval → Deploy PROD → Test PROD → [Optional Destroy Approval] → Destroy DEV
```

**Additional resources (variant-owned):**
- 1 CodeBuild Project: `<project>-destroy` — runs `terraform destroy` against DEV
- 1 CloudWatch Log Group: `/codebuild/<project>-destroy`

**Destroy stage details:**
- Uses the same CodeBuild service role from core (no new IAM role)
- Assumes DEV deployment role via `sts:AssumeRole`
- Runs `terraform init` + `terraform destroy -auto-approve` against DEV state
- Buildspec: `modules/default-dev-destroy/buildspecs/destroy.yml`

**Optional approval gate:**
- Controlled by `enable_destroy_approval` variable (default: `true` — safe by default)
- When enabled, inserts a manual approval stage before the destroy stage
- Uses the same SNS topic as the mandatory PROD approval

## Repository Structure

```
terraform-pipelines/
├── modules/
│   ├── core/                          # Internal shared module
│   │   ├── main.tf                    # CodeBuild projects (x4), CloudWatch log groups (x4)
│   │   ├── iam.tf                     # IAM roles + policies (CodePipeline SR, CodeBuild SR)
│   │   ├── storage.tf                 # S3 buckets, SNS topic, subscriptions
│   │   ├── codestar.tf                # CodeStar Connection (conditional)
│   │   ├── variables.tf               # All inputs needed by core resources
│   │   ├── outputs.tf                 # All resource references for variant wrappers
│   │   ├── locals.tf                  # Computed values
│   │   ├── versions.tf                # Terraform >= 1.11, AWS ~> 6.0
│   │   └── buildspecs/               # Shared buildspec files
│   │       ├── prebuild.yml
│   │       ├── plan.yml
│   │       ├── deploy.yml
│   │       └── test.yml
│   │
│   ├── default/                       # Default variant wrapper
│   │   ├── main.tf                    # module "core" + CodePipeline (9 stages)
│   │   ├── variables.tf               # Uniform interface
│   │   ├── outputs.tf                 # Uniform outputs
│   │   └── versions.tf
│   │
│   └── default-dev-destroy/           # Default-DevDestroy variant wrapper
│       ├── main.tf                    # module "core" + CodePipeline (10-11 stages) + destroy CB project
│       ├── variables.tf               # Uniform interface + enable_destroy_approval
│       ├── outputs.tf                 # Uniform outputs
│       ├── versions.tf
│       └── buildspecs/
│           └── destroy.yml            # Variant-specific destroy buildspec
│
├── examples/
│   ├── default/
│   │   ├── minimal/                   # Required variables only
│   │   ├── complete/                  # All variables with production overrides
│   │   ├── opentofu/                  # OpenTofu runtime example
│   │   └── single-account/            # Same-account DEV/PROD deployment
│   └── default-dev-destroy/
│       └── minimal/
│
├── tests/
│   ├── default/                       # Default variant validation
│   └── default-dev-destroy/           # Default-dev-destroy variant validation
│
├── docs/
│   ├── ARCHITECTURE_AND_DESIGN.md     # This file (high-level multi-variant architecture)
│   ├── codepipeline-mvp-statement.md  # Original MVP specification
│   ├── shared/                        # Core module docs + shared assets
│   │   └── diagrams/                  # Architecture diagrams (PNG)
│   │       ├── three-account-model.png
│   │       ├── pipeline-stages.png
│   │       ├── pipeline-sequence.png
│   │       ├── pipeline-sequence-flow.png
│   │       ├── artifact-flow.png
│   │       ├── resource-dependencies.png
│   │       └── cross-account-credentials.png
│   ├── default/                       # Default variant-specific docs
│   └── default-dev-destroy/          # Default-dev-destroy variant-specific docs
│
├── CLAUDE.md
├── README.md
├── CHANGELOG.md
├── prd.md
├── progress.txt
└── .gitignore
```

## Buildspec Strategy

Shared buildspecs live in `modules/core/buildspecs/`. All variants reference these via `file("${path.module}/../core/buildspecs/<name>.yml")`.

Variant-specific buildspecs live in the variant's own `buildspecs/` directory. The Default-DevDestroy variant adds `destroy.yml`.

| Buildspec | Location | Used By |
|-----------|----------|---------|
| `prebuild.yml` | `modules/core/buildspecs/` | All variants (Stage 2) |
| `plan.yml` | `modules/core/buildspecs/` | All variants (Stage 3) |
| `deploy.yml` | `modules/core/buildspecs/` | All variants (Stages 5, 8) |
| `test.yml` | `modules/core/buildspecs/` | All variants (Stages 6, 9) |
| `destroy.yml` | `modules/default-dev-destroy/buildspecs/` | Default-DevDestroy only (Stage 10/11) |

## Security Model

All security controls from the original monolithic module are preserved in the core module. See `docs/shared/` for the detailed security model including:

- AWS Security Hub controls alignment (CodeBuild.1–5)
- CodePipeline security best practices
- Well-Architected pipeline security (SEC11-BP07)
- Encryption at rest (SSE-S3, KMS for SNS)
- Cross-account credential flow (STS AssumeRole, first-hop, no chaining)
- S3 access control (SSL-only, Block Public Access)
- IAM least privilege (scoped to exact deployment role ARNs)
- SCP compatibility

### Destroy Stage Security (Default-DevDestroy)

- Uses the same CodeBuild service role from core — no privilege escalation
- Assumes DEV deployment role via `sts:AssumeRole` — same credential flow as deploy
- `terraform destroy -auto-approve` runs only after PROD tests pass (Stage 9 success)
- Optional `enable_destroy_approval` gate adds human oversight for destructive action
- Destroy is limited to DEV environment only — PROD is never destroyed by the pipeline

## Input Variables (Uniform Interface)

All variants expose the same base variable interface. See `prd.md` for the complete variable table.

**Required (6):** `project_name`, `github_repo`, `dev_account_id`, `dev_deployment_role_arn`, `prod_account_id`, `prod_deployment_role_arn`

**Optional (19):** `github_branch`, `iac_runtime`, `iac_version`, `codestar_connection_arn`, `create_state_bucket`, `state_bucket`, `state_key_prefix`, `sns_subscribers`, `enable_review_gate`, `codebuild_compute_type`, `codebuild_image`, `checkov_soft_fail`, `codebuild_timeout_minutes`, `logging_bucket`, `logging_prefix`, `log_retention_days`, `artifact_retention_days`, `tags`

**Variant-specific:** Default-DevDestroy adds `enable_destroy_approval` (bool, default: true)

## Design Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Shared core + overlay pattern | Eliminates duplication of IAM, S3, CodeBuild, logging across variants. Core changes propagate to all variants. |
| 2 | Core is internal only | Prevents consumers from bypassing variant abstractions. Variants provide the stable API. |
| 3 | Variants own CodePipeline | Stage configurations are the primary differentiator between variants. Keeping CodePipeline in the variant gives full control over stage composition. |
| 4 | Uniform variable interface | Consumers can switch variants without changing their variable definitions. Reduces migration friction. |
| 5 | Separate module calls (not variant variable) | Each variant is a distinct module source. Avoids complex conditional logic within a single module. Clearer separation of concerns. |
| 6 | Destroy CodeBuild project owned by variant | Only Default-DevDestroy needs it. Keeps core module clean and avoids conditional resource complexity for a single-variant concern. |
| 7 | Destroy reuses CodeBuild service role from core | Same permissions are needed (sts:AssumeRole to DEV deployment role). No benefit to a restricted role since destroy requires the same S3/state/logs access. |
| 8 | State key isolation for Single-Account | Same-account DEV/PROD isolation via `<project>/dev/terraform.tfstate` vs `<project>/prod/terraform.tfstate`. Simplest isolation mechanism when accounts are the same. |
| 9 | Consumer still provides role ARNs for Single-Account | Maintains least-privilege even within a single account. CodeBuild assumes a scoped deployment role rather than using its service role for everything. |
| 10 | Configurable destroy approval gate | Default is approval required (safe by default). `enable_destroy_approval = false` enables auto-destroy after PROD success for teams that want fully automated ephemeral DEV. |
| 11 | Per-variant examples and tests | Each variant gets its own examples/ and tests/ subdirectory. Ensures variant-specific behavior is validated independently. |
| 12 | Nested docs structure | `docs/shared/` for core, `docs/<variant>/` for variant-specific docs. Mirrors the module structure and scales with new variants. |
| 13–24 | Original design decisions preserved | See `docs/shared/` for decisions #13–24 from the original architecture document (encryption strategy, conditional resources, validation blocks, tag patterns, etc.) |

## Deployment Workflow

### Consumer Usage (Default Variant)

```hcl
module "my_pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "222222222222"
  dev_deployment_role_arn  = "arn:aws:iam::222222222222:role/TerraformDeploy-dev"
  prod_account_id          = "333333333333"
  prod_deployment_role_arn = "arn:aws:iam::333333333333:role/TerraformDeploy-prod"
}
```

### Consumer Usage (Single-Account via Default Variant)

```hcl
module "my_pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "222222222222"
  dev_deployment_role_arn  = "arn:aws:iam::222222222222:role/TerraformDeploy"
  prod_account_id          = "222222222222"  # Same account — isolation via state keys
  prod_deployment_role_arn = "arn:aws:iam::222222222222:role/TerraformDeploy"
}
```

### Consumer Usage (Default-DevDestroy Variant)

```hcl
module "my_pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default-dev-destroy"

  project_name              = "my-project"
  github_repo               = "my-org/my-project"
  dev_account_id            = "222222222222"
  dev_deployment_role_arn   = "arn:aws:iam::222222222222:role/TerraformDeploy-dev"
  prod_account_id           = "333333333333"
  prod_deployment_role_arn  = "arn:aws:iam::333333333333:role/TerraformDeploy-prod"
  enable_destroy_approval   = true  # Optional: require approval before DEV destroy
}
```

## Cost Estimate

Per-pipeline costs remain identical to the original module (~$2.65/month at moderate use). The Default-DevDestroy variant adds approximately $0.15/month for the additional destroy CodeBuild execution (20 runs x ~3 min x $0.005/min).

See `docs/shared/` for the full cost breakdown table.

## Test Environment

| Account | Account ID | CLI Profile | Role |
|---------|-----------|-------------|------|
| Automation | 389068787156 | `aft-automation` | Pipeline host |
| DEV Target | 914089393341 | `developer-account` | DEV deployment target |
| PROD Target | 264675080489 | `network` | PROD deployment target |

**Test Repository:** `OttawaCloudConsulting/terraform-test`, branch `s3-bucket`

### Cross-Account Role Chain

```
aft-automation account (389068787156)
├── org-automation-broker-role
│   └── Assumes (role-chain) →
│       ├── org-default-deployment-role (in target accounts)
│       └── application-default-deployment-role (in target accounts)
│
└── CodeBuild-<project>-ServiceRole (created by terraform-pipelines module)
    └── Assumes (direct, first-hop) →
        └── org-default-deployment-role (in target accounts)
```

**Deployment role in target accounts:** `org-default-deployment-role`
- DEV: `arn:aws:iam::914089393341:role/org-default-deployment-role`
- PROD: `arn:aws:iam::264675080489:role/org-default-deployment-role`

## Dependency Graph

### Module Dependency Graph

```
Consumer Root Module
    │
    ▼
Variant Wrapper (default | default-dev-destroy)
    │
    ├──► module "core" (modules/core/)
    │       │
    │       ├── IAM Roles + Policies
    │       ├── S3 Buckets (state conditional + artifacts)
    │       ├── SNS Topic + Subscriptions
    │       ├── CodeStar Connection (conditional)
    │       ├── CloudWatch Log Groups (x4)
    │       └── CodeBuild Projects (x4)
    │
    ├──► CodePipeline V2 (variant-specific stages)
    │       depends on: core.codebuild_project_names,
    │                   core.codepipeline_service_role_arn,
    │                   core.artifact_bucket_name,
    │                   core.codestar_connection_arn,
    │                   core.sns_topic_arn
    │
    └──► [Default-DevDestroy only]
            ├── Destroy CodeBuild Project
            │     depends on: core.codebuild_service_role_arn
            └── Destroy CloudWatch Log Group
```

### Creation Order (Terraform resolves automatically)

1. Core resources (S3, SNS, CodeStar, log groups) — independent, parallel
2. Core IAM roles + policies — depend on bucket ARNs, log group ARNs
3. Core CodeBuild projects — depend on IAM role, log groups
4. Variant-specific resources (destroy CB project, if applicable) — depend on core outputs
5. CodePipeline — depends on everything above

## Out of Scope

| Item | Rationale |
|------|-----------|
| Deployment roles in target accounts | Prerequisite. Trust and permission policies documented in MVP statement. |
| Custom Docker images | Adds build/maintain/patch lifecycle. Standard images + inline install. |
| Automated approval | Lambda + PutApprovalResult is post-MVP. |
| Multi-environment beyond DEV/PROD | Each pipeline deploys to exactly two environments. |
| Core module as public API | Consumers must use variant wrappers. |
| Dynamic stage composition | Variants have fixed stages. No runtime stage selection. |
| Cross-variant migration tooling | Consumers re-deploy with the new variant source. |
| Customer-managed KMS keys | Post-MVP. SSE-S3 sufficient for single-account artifact access. |

## References

- [AWS CodePipeline Security Best Practices](https://docs.aws.amazon.com/codepipeline/latest/userguide/security-best-practices.html)
- [AWS Security Hub CodeBuild Controls](https://docs.aws.amazon.com/securityhub/latest/userguide/codebuild-controls.html)
- [AWS Well-Architected SEC11-BP07: Pipeline Security](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/sec_appsec_regularly_assess_security_properties_of_pipelines.html)
- [AWS Prescriptive Guidance: Terraform AWS Provider Best Practices](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/introduction.html)
- [AWS Prescriptive Guidance: S3 Encryption Best Practices](https://docs.aws.amazon.com/prescriptive-guidance/latest/encryption-best-practices/s3.html)
- [AWS IAM Best Practices](https://aws.amazon.com/iam/resources/best-practices/)
