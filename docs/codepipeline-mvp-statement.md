# MVP Statement: AWS CodePipeline for Terraform/OpenTofu CI/CD

**Prepared for:** Ottawa Cloud Consulting — Architecture & Project Team
**Date:** February 12, 2026
**Status:** Draft — Pending Architecture Review
**Author:** Claude (AI-Assisted Analysis)
**Companion Documents:**
- Terraform/OpenTofu CI/CD Pipeline: Technology Comparison
- Terraform CI/CD Pipeline: Reference Architectures

---

## Table of Contents

1. [Purpose](#purpose)
2. [MVP Definition](#mvp-definition)
3. [Scope](#scope)
4. [Architecture Overview](#architecture-overview)
5. [Pipeline Parameters](#pipeline-parameters)
6. [Pipeline Design](#pipeline-design)
7. [AWS Account Structure & IAM](#aws-account-structure--iam)
8. [Target Account Deployment Role Requirements](#target-account-deployment-role-requirements)
9. [State Management](#state-management)
10. [Approval Workflow & Notifications](#approval-workflow--notifications)
11. [Secrets Management](#secrets-management)
12. [Source Control Integration](#source-control-integration)
13. [Prerequisites](#prerequisites)
14. [Implementation Phases](#implementation-phases)
15. [Cost Estimate](#cost-estimate)
16. [Success Criteria](#success-criteria)
17. [Assumptions & Constraints](#assumptions--constraints)
18. [Risks & Mitigations](#risks--mitigations)
19. [Post-MVP Enhancements](#post-mvp-enhancements)

---

## Purpose

This document defines the Minimum Viable Product (MVP) for an AWS CodePipeline-based CI/CD solution that deploys Terraform or OpenTofu infrastructure-as-code across a multi-account AWS Control Tower environment. The MVP delivers a repeatable, parameterized pipeline template that is deployed once per Terraform project — each pipeline is 1:1 with a Terraform project. The pipeline promotes infrastructure changes from development through production with appropriate approval gates, testing, and governance.

The intended audience is the architecture and project team responsible for design approval, implementation, and operational ownership.

---

## MVP Definition

The MVP delivers a **parameterized, reusable pipeline template** that provisions a dedicated CodePipeline for each Terraform project. Each pipeline:

1. Triggers automatically on code push to a configurable branch (default: `main`).
2. Runs pre-deployment validation by executing a developer-managed shell script at `cicd/prebuild/main.sh`.
3. Generates a Terraform or OpenTofu plan with security scanning applied to the plan output.
4. Supports an optional human review gate.
5. Deploys to the DEV environment (configurable target account).
6. Runs post-deployment tests by executing a developer-managed shell script at `cicd/dev/smoke-test.sh`.
7. Enforces a mandatory human approval gate before production.
8. Deploys to the PROD environment (configurable target account).
9. Runs post-deployment tests by executing a developer-managed shell script at `cicd/prod/smoke-test.sh`.

**Key design principle:** Developers own their validation and test logic. The pipeline provides the orchestration framework and cross-account credential mechanics. Developers provide the content of pre-build scripts, smoke tests, and any additional tool dependencies they need — installed inline via `apt-get`, `yum`, or `pip` within their own scripts.

---

## Scope

### In Scope (MVP)

| Item | Detail |
|------|--------|
| **Pipeline orchestration** | AWS CodePipeline V2 in the Automation Account; one pipeline per Terraform project |
| **Build/execution engine** | AWS CodeBuild using standard managed images (no custom Docker images) |
| **IaC runtime** | Either Terraform **or** OpenTofu per pipeline — mutually exclusive, configurable as a parameter |
| **Source trigger** | GitHub via AWS CodeStar Connection; configurable branch (default: `main`) |
| **Pre-build validation** | Pipeline executes `cicd/prebuild/main.sh` from the project repo; developers manage content and install their own tools (tflint, checkov, etc.) |
| **Terraform plan** | Plan with security scanning; output visible in CodeBuild results |
| **Approval gates** | CodePipeline Manual Approval action with SNS notification |
| **Cross-account deployment** | IAM role assumption from Automation Account → configurable target accounts |
| **Post-deploy testing** | Pipeline executes `cicd/dev/smoke-test.sh` and `cicd/prod/smoke-test.sh` from the project repo; developers manage content |
| **State management** | S3 backend in Automation Account with versioning and native S3 locking (`use_lockfile = true`) |
| **Secrets (two types)** | Automation Secrets in Automation Account; Application Secrets in each target account |
| **Notifications** | SNS topic with optional subscriber list; email for approval requests |
| **Audit** | CloudTrail logging for all IAM, STS, and pipeline actions |
| **Target accounts** | Configurable as parameters when the pipeline is created |
| **Deployment roles** | Configurable as parameters; existing roles in target accounts are referenced, not created |
| **CodeStar Connection** | Optional parameter; use an existing connection or create one automatically |
| **CodeBuild runtime** | Configurable as a parameter (compute type, image) |

### Out of Scope (MVP)

| Item | Rationale |
|------|-----------|
| **Custom CodeBuild Docker images** | Post-MVP enhancement. MVP uses standard managed images with inline tool installation via developer shell scripts. |
| **Automated (programmatic) approval** | MVP uses human click-ops. Lambda + `PutApprovalResult` pattern is a post-MVP enhancement. |
| **Drift detection** | Not natively supported by CodePipeline. Post-MVP: scheduled `terraform plan` with SNS alert on changes. |
| **Cost estimation (Infracost)** | Nice-to-have. Can be added by developers in their `cicd/prebuild/main.sh` script. |
| **Policy-as-code (OPA/Sentinel)** | Post-MVP enhancement. MVP relies on IAM permission boundaries and SCPs for governance. |
| **GitHub PR plan comments** | Posting `terraform plan` output to PR comments requires a Lambda webhook. Post-MVP. |
| **Self-service pipeline provisioning** | Teams requesting new pipelines is a process/tooling item beyond MVP. |
| **Rollback automation** | Terraform does not have native rollback. Post-MVP: plan/apply the previous commit as a workaround. |
| **Approve-from-Slack** | Requires custom Lambda + API Gateway. MVP approval is via email link → CodePipeline console. |
| **Creating deployment roles in target accounts** | Pipeline references existing roles. Role creation and permission management is the responsibility of the account/security team. Requirements and example Terraform code are documented. |

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                          Automation Account                           │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │            AWS CodePipeline V2 (one per TF project)          │    │
│  │                                                              │    │
│  │  Source ─► Pre-Build ─► Plan ─► [Optional   ─► Deploy  ─►   │    │
│  │  (GitHub)  (cicd/       (CB +    Approval]     DEV (CB)     │    │
│  │            prebuild/    security                  │          │    │
│  │            main.sh)     scan)               cicd/dev/        │    │
│  │                                             smoke-test.sh    │    │
│  │                                                  │           │    │
│  │                                             Mandatory        │    │
│  │                                             Approval (SNS)   │    │
│  │                                                  │           │    │
│  │                                             Deploy PROD (CB) │    │
│  │                                                  │           │    │
│  │                                             cicd/prod/       │    │
│  │                                             smoke-test.sh    │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                       │
│  ┌──────────────────┐  ┌───────────────────────────────────────┐    │
│  │  S3: TF State     │  │  IAM Roles                            │    │
│  │  (versioned,      │  │  - CodePipeline Service Role          │    │
│  │   encrypted,      │  │  - CodeBuild Service Role             │    │
│  │   use_lockfile)   │  │    (can AssumeRole to target accts)   │    │
│  └──────────────────┘  └───────────────────────────────────────┘    │
│                                                                       │
│  ┌──────────────────┐  ┌───────────────────────────────────────┐    │
│  │  SNS Topic:       │  │  Automation Secrets                    │    │
│  │  Pipeline-Approvals│  │  (Secrets Manager / Parameter Store)  │    │
│  │  (optional         │  │  Pipeline-specific secrets only       │    │
│  │   subscribers)     │  │                                       │    │
│  └──────────────────┘  └───────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
         │                          │                    │
         │ CodeStar                 │ AssumeRole         │ AssumeRole
         │ Connection               ▼                    ▼
         ▼                  ┌──────────────┐    ┌──────────────────┐
    ┌─────────┐             │ DEV Target    │    │ PROD Target       │
    │ GitHub  │             │ Account       │    │ Account            │
    │ (Source │             │ (configurable)│    │ (configurable)     │
    │  Repo)  │             │              │    │                    │
    └─────────┘             │ Deployment   │    │ Deployment         │
                            │ Role         │    │ Role               │
                            │ (configurable│    │ (configurable      │
                            │  parameter)  │    │  parameter)        │
                            │              │    │                    │
                            │ Application  │    │ Application        │
                            │ Secrets      │    │ Secrets            │
                            └──────────────┘    └──────────────────┘
```

### Key Design Decisions

**Why CodePipeline?** The cross-account analysis in the companion comparison document identified CodePipeline as co-primary recommendation alongside GitHub Actions. For this MVP, CodePipeline's structural advantages in a Control Tower environment are decisive: no role chaining session limits, no external trust boundaries, all plan/state data stays within AWS accounts, native SCP compatibility, and native CloudTrail auditability. Cost is also the lowest evaluated option.

**Why one pipeline per project?** Each Terraform project has its own lifecycle, target accounts, deployment role, state file, and approval cadence. A 1:1 mapping keeps blast radius small and configuration simple. The pipeline template is parameterized so that spinning up a new pipeline for a new project is a matter of providing variable values, not rebuilding infrastructure.

**Why standard CodeBuild images (no custom Docker)?** Custom Docker images add a build/maintain/patch lifecycle that complicates the MVP. Standard managed images with inline tool installation (`apt-get`, `pip`, etc.) within developer-managed shell scripts are simpler to operate. Developers control their own tool versions and dependencies. Custom images are a post-MVP enhancement for teams that need faster build times or pinned tool versions.

**Why Terraform OR OpenTofu (not both)?** A single pipeline targets one IaC runtime. Mixing runtimes in the same pipeline creates state compatibility risks. The runtime is a pipeline parameter — deploying a project with OpenTofu simply means setting the parameter to `opentofu` instead of `terraform`.

**Why not GitHub Actions?** GitHub Actions remains a valid co-primary option with better developer experience. The MVP uses CodePipeline because the architecture team's priority is keeping the entire CI/CD footprint within the AWS perimeter. A future iteration could use GitHub Actions as the outer orchestrator with CodePipeline/CodeBuild handling deployment stages.

---

## Pipeline Parameters

The pipeline template accepts the following parameters when a new pipeline is provisioned for a Terraform project. This makes each pipeline instance configurable without modifying the template itself.

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `project_name` | Yes | — | Name of the Terraform project. Used to name pipeline resources (e.g., `<project_name>-pipeline`). |
| `github_repo` | Yes | — | GitHub repository in `org/repo` format. |
| `github_branch` | No | `main` | Branch to trigger the pipeline on push. |
| `iac_runtime` | No | `terraform` | IaC tool to use: `terraform` or `opentofu`. Mutually exclusive — one binary is installed, not both. |
| `iac_version` | No | `latest` | Version of Terraform or OpenTofu to install (e.g., `1.9.5`, `1.8.0`). |
| `dev_account_id` | Yes | — | AWS Account ID for the DEV target environment. |
| `dev_deployment_role_arn` | Yes | — | ARN of the existing IAM role in the DEV account that CodeBuild will assume for deployment. |
| `prod_account_id` | Yes | — | AWS Account ID for the PROD target environment. |
| `prod_deployment_role_arn` | Yes | — | ARN of the existing IAM role in the PROD account that CodeBuild will assume for deployment. |
| `codestar_connection_arn` | No | `""` (empty) | ARN of an existing CodeStar Connection. If empty, the pipeline creates a new connection automatically. |
| `sns_subscribers` | No | `[]` (empty) | List of email addresses to subscribe to the SNS approval topic. If empty, the topic is created with no subscribers. |
| `codebuild_compute_type` | No | `BUILD_GENERAL1_SMALL` | CodeBuild compute type (e.g., `BUILD_GENERAL1_SMALL`, `BUILD_GENERAL1_MEDIUM`). |
| `codebuild_image` | No | `aws/codebuild/amazonlinux-x86_64-standard:5.0` | CodeBuild managed image identifier. |
| `state_bucket` | Yes | — | S3 bucket name for Terraform state in the Automation Account. |
| `state_key_prefix` | No | `<project_name>` | S3 key prefix for state files (e.g., `myproject/dev/terraform.tfstate`). |

---

## Pipeline Design

### Stage Map

Each pipeline instance has nine CodePipeline stages. Stages that execute developer code reference standardized file paths within the project repository.

| # | Stage | CodePipeline Action Type | Executes | Trigger |
|---|-------|--------------------------|----------|---------|
| 1 | **Source** | Source (CodeStar Connection) | — | Push to configured branch |
| 2 | **Pre-Build** | Build (CodeBuild) | `cicd/prebuild/main.sh` | Automatic |
| 3 | **Plan + Security Scan** | Build (CodeBuild) | `terraform plan` + security scan on plan output | Automatic |
| 4 | **Optional Review** | Manual Approval | — | Manual (configurable) |
| 5 | **Deploy DEV** | Build (CodeBuild) | `terraform apply` to DEV target account | Automatic (after approval) |
| 6 | **Test DEV** | Build (CodeBuild) | `cicd/dev/smoke-test.sh` | Automatic |
| 7 | **Mandatory Approval** | Manual Approval + SNS | — | Manual (required) |
| 8 | **Deploy PROD** | Build (CodeBuild) | `terraform apply` to PROD target account | Automatic (after approval) |
| 9 | **Test PROD** | Build (CodeBuild) | `cicd/prod/smoke-test.sh` | Automatic |

### Stage Detail

**Stage 1 — Source:** CodePipeline uses an AWS CodeStar Connection to pull the repository contents from GitHub on every push to the configured branch (default: `main`). If no `codestar_connection_arn` parameter is provided, the pipeline creates a new connection automatically. Source artifacts are stored in an S3 artifact bucket in the Automation Account.

**Stage 2 — Pre-Build:** A CodeBuild project executes the developer-managed shell script at `cicd/prebuild/main.sh` from the project repository. Developers are responsible for the content of this script, which typically includes formatting checks (`terraform fmt -check`), linting (`tflint`), syntax validation (`terraform validate`), and static security analysis (`checkov`). Developers install any required tools inline (e.g., `apt-get install -y tflint` or `pip install checkov`) — this gives teams control over tool versions and the ability to add project-specific dependencies. If the script exits non-zero, the pipeline stops. No AWS credentials for target accounts are needed — this stage only validates code.

**Stage 3 — Plan + Security Scan:** A CodeBuild project installs the configured IaC runtime (Terraform or OpenTofu — not both), initializes against the S3 backend, and runs `terraform plan -out=tfplan`. After plan generation, security scanning is applied to the plan output (e.g., `checkov -f tfplan.json` or `tfsec --tfplan`). The plan output and scan results are saved as pipeline artifacts and are visible in the CodeBuild build logs. The plan file is passed to the apply stage so the exact reviewed plan is what gets applied.

**Stage 4 — Optional Review:** A Manual Approval action that the pipeline can include for high-risk changes. When active, it publishes a notification to the SNS topic and waits up to 7 days for a response. This stage can be toggled on or off per pipeline configuration.

**Stage 5 — Deploy DEV:** A CodeBuild project assumes the deployment role specified by `dev_deployment_role_arn` in the DEV target account and runs `terraform apply` using the saved plan artifact from Stage 3. Because CodeBuild's service role credentials are "first-hop" (not role-chained), there is no 1-hour session limit.

**Stage 6 — Test DEV:** A CodeBuild project executes the developer-managed shell script at `cicd/dev/smoke-test.sh` from the project repository. Developers are responsible for the content — smoke tests, integration tests, API checks, resource validation, etc. The pipeline assumes the DEV deployment role so the test script has credentials for the DEV account. Developers install any test dependencies inline (e.g., `pip install boto3 pytest`). If the script exits non-zero, the pipeline stops before the production approval gate.

**Stage 7 — Mandatory Approval:** A Manual Approval action that cannot be skipped. When the pipeline reaches this stage, it publishes a notification to the SNS approval topic. If subscribers were specified in `sns_subscribers`, they receive an email with a direct link to the CodePipeline console. The reviewer clicks Approve (with optional comment) or Reject. The decision is logged in CloudTrail. If no action is taken within 7 days, the pipeline fails.

**Stage 8 — Deploy PROD:** Same structure as Stage 5, but assumes the deployment role specified by `prod_deployment_role_arn` in the PROD target account.

**Stage 9 — Test PROD:** A CodeBuild project executes the developer-managed shell script at `cicd/prod/smoke-test.sh` from the project repository. PROD tests should be non-destructive and read-only. Same execution model as Stage 6.

### Developer-Managed CI/CD Scripts

Developers own the content of three shell scripts at standardized paths. The pipeline guarantees these scripts will be executed at the correct stage with appropriate credentials, but what they do is the developer's responsibility.

```
<project-repo>/
├── cicd/
│   ├── prebuild/
│   │   └── main.sh              # Stage 2: Pre-build validation
│   │                            # Developers install tools and run checks:
│   │                            #   apt-get install -y tflint
│   │                            #   pip install checkov
│   │                            #   terraform fmt -check
│   │                            #   tflint --init && tflint
│   │                            #   terraform validate
│   │                            #   checkov -d .
│   │
│   ├── dev/
│   │   └── smoke-test.sh        # Stage 6: Post-deploy DEV tests
│   │                            # Developers install test tools and validate:
│   │                            #   pip install boto3 pytest
│   │                            #   pytest tests/ -v --env=dev
│   │                            #   ./scripts/health-check.sh dev
│   │
│   └── prod/
│       └── smoke-test.sh        # Stage 9: Post-deploy PROD tests
│                                # Non-destructive, read-only validation:
│                                #   pip install boto3
│                                #   python tests/smoke_test.py --env=prod
```

### Buildspec Structure

The pipeline provides buildspec files that invoke the developer scripts. These are managed by the pipeline template, not the developer.

**buildspec-prebuild.yml** — Invokes `cicd/prebuild/main.sh`:

```yaml
version: 0.2
phases:
  install:
    runtime-versions:
      python: 3.x
    commands:
      # Install configured IaC runtime
      - |
        if [ "$IAC_RUNTIME" = "opentofu" ]; then
          curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone --opentofu-version $IAC_VERSION
        else
          curl -fsSL https://releases.hashicorp.com/terraform/${IAC_VERSION}/terraform_${IAC_VERSION}_linux_amd64.zip -o tf.zip
          unzip -o tf.zip -d /usr/local/bin && rm tf.zip
        fi
  build:
    commands:
      - chmod +x cicd/prebuild/main.sh
      - ./cicd/prebuild/main.sh
```

**buildspec-plan.yml** — Runs plan and security scan:

```yaml
version: 0.2
env:
  variables:
    TARGET_ENV: "dev"
phases:
  install:
    runtime-versions:
      python: 3.x
    commands:
      # Install IaC runtime
      - |
        if [ "$IAC_RUNTIME" = "opentofu" ]; then
          curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone --opentofu-version $IAC_VERSION
        else
          curl -fsSL https://releases.hashicorp.com/terraform/${IAC_VERSION}/terraform_${IAC_VERSION}_linux_amd64.zip -o tf.zip
          unzip -o tf.zip -d /usr/local/bin && rm tf.zip
        fi
      # Install security scanning tools
      - pip install checkov
  build:
    commands:
      - terraform init -backend-config="bucket=${STATE_BUCKET}" -backend-config="key=${STATE_KEY_PREFIX}/${TARGET_ENV}/terraform.tfstate" -backend-config="region=${AWS_REGION}" -backend-config="use_lock_file=true"
      - terraform plan -out=tfplan -var-file=environments/${TARGET_ENV}.tfvars
      # Convert plan to JSON for security scanning
      - terraform show -json tfplan > tfplan.json
      # Security scan on plan output
      - checkov -f tfplan.json --framework terraform_plan --output cli --output junitxml --output-file-path . || true
      - echo "--- PLAN SUMMARY ---"
      - terraform show tfplan
artifacts:
  files:
    - tfplan
    - tfplan.json
    - '**/*'
reports:
  security-scan:
    files:
      - results_junitxml.xml
    file-format: JUNITXML
```

**buildspec-deploy.yml** — Runs apply with cross-account role:

```yaml
version: 0.2
env:
  variables:
    TARGET_ROLE: ""
    TARGET_ENV: ""
phases:
  install:
    runtime-versions:
      python: 3.x
    commands:
      - |
        if [ "$IAC_RUNTIME" = "opentofu" ]; then
          curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone --opentofu-version $IAC_VERSION
        else
          curl -fsSL https://releases.hashicorp.com/terraform/${IAC_VERSION}/terraform_${IAC_VERSION}_linux_amd64.zip -o tf.zip
          unzip -o tf.zip -d /usr/local/bin && rm tf.zip
        fi
  pre_build:
    commands:
      # Assume target account deployment role (first hop — no chaining limit)
      - >
        CREDS=$(aws sts assume-role
        --role-arn $TARGET_ROLE
        --role-session-name "codebuild-${CODEBUILD_BUILD_ID}"
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'
        --output text)
      - export AWS_ACCESS_KEY_ID=$(echo $CREDS | awk '{print $1}')
      - export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | awk '{print $2}')
      - export AWS_SESSION_TOKEN=$(echo $CREDS | awk '{print $3}')
      - aws sts get-caller-identity  # Verify we're in the target account
  build:
    commands:
      - terraform init -backend-config="bucket=${STATE_BUCKET}" -backend-config="key=${STATE_KEY_PREFIX}/${TARGET_ENV}/terraform.tfstate" -backend-config="region=${AWS_REGION}" -backend-config="use_lock_file=true"
      - terraform apply -var-file=environments/${TARGET_ENV}.tfvars -auto-approve
```

**buildspec-test.yml** — Invokes developer smoke test:

```yaml
version: 0.2
env:
  variables:
    TARGET_ROLE: ""
    TARGET_ENV: ""
phases:
  install:
    runtime-versions:
      python: 3.x
  pre_build:
    commands:
      # Assume target account role so test scripts have credentials
      - >
        CREDS=$(aws sts assume-role
        --role-arn $TARGET_ROLE
        --role-session-name "codebuild-test-${CODEBUILD_BUILD_ID}"
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'
        --output text)
      - export AWS_ACCESS_KEY_ID=$(echo $CREDS | awk '{print $1}')
      - export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | awk '{print $2}')
      - export AWS_SESSION_TOKEN=$(echo $CREDS | awk '{print $3}')
  build:
    commands:
      - chmod +x cicd/${TARGET_ENV}/smoke-test.sh
      - ./cicd/${TARGET_ENV}/smoke-test.sh
```

### Security Scan Visibility

The Plan stage uses CodeBuild **report groups** (via the `reports` section in the buildspec) to publish security scan results as structured test reports. This means scan results are visible directly in the CodeBuild console under the "Reports" tab — not buried in log output. The JUnit XML format provides pass/fail counts, finding details, and severity levels in a structured view.

Additionally, the full `terraform show tfplan` output is echoed to the build log under a `--- PLAN SUMMARY ---` header, so reviewers can see the plan output in the CodeBuild logs without downloading artifacts.

---

## AWS Account Structure & IAM

### Accounts

| Account | Role in MVP | Key Resources |
|---------|------------|---------------|
| **Automation Account** | Pipeline host, state storage, automation secrets | CodePipeline(s), CodeBuild, S3 state bucket, SNS topics, Secrets Manager (automation secrets), CodeStar Connection |
| **DEV Target Account** (configurable) | Target for DEV deployments | Deployment role (pre-existing, passed as parameter), Application Secrets, deployed infrastructure |
| **PROD Target Account** (configurable) | Target for PROD deployments | Deployment role (pre-existing, passed as parameter), Application Secrets, deployed infrastructure |

### IAM Roles (Automation Account — Created by Pipeline)

The pipeline template creates the following roles in the Automation Account:

| Role | Trust Principal | Purpose |
|------|----------------|---------|
| `CodePipeline-<project>-ServiceRole` | `codepipeline.amazonaws.com` | Orchestrates pipeline stages, accesses S3 artifact bucket |
| `CodeBuild-<project>-ServiceRole` | `codebuild.amazonaws.com` | Executes builds; can `sts:AssumeRole` into DEV and PROD target accounts; reads S3 state bucket; reads Automation Secrets |

### IAM Roles (Target Accounts — NOT Created by Pipeline)

Deployment roles in the DEV and PROD target accounts are **not created by the pipeline**. They must already exist and their ARNs are passed as parameters (`dev_deployment_role_arn`, `prod_deployment_role_arn`). This allows teams to use existing roles and maintain separation of responsibility — the pipeline team manages orchestration, the account/security team manages permissions.

See [Target Account Deployment Role Requirements](#target-account-deployment-role-requirements) for trust policy, permissions, and example Terraform code.

### Cross-Account Credential Flow

```
CodePipeline triggers CodeBuild
    │
    ▼
CodeBuild assumes its Service Role (codebuild.amazonaws.com)
    │  "First-hop" credentials — NOT role-chained
    │  Session duration: up to 8 hours (CodeBuild timeout)
    │
    │ sts:AssumeRole (first hop, no chaining limit)
    ├──────────────────────────────────────┐
    ▼                                      ▼
DEV Target Account                    PROD Target Account
<dev_deployment_role_arn>             <prod_deployment_role_arn>
    Session: up to 12h                    Session: up to 12h
    (configurable on role)                (configurable on role)
```

**Why this avoids the 1-hour chaining limit:** CodeBuild's service role is assumed by the CodeBuild service principal — not by another assumed-role session. The resulting credentials are "first-hop." When they call `sts:AssumeRole` into the target account, it's only the first role assumption in the chain.

### SCP Compatibility

The design is fully compatible with standard Control Tower SCPs because:

- All principals are within the AWS Organization (no external trust).
- No role chaining from external OIDC providers.
- Region-deny SCPs are respected — the pipeline must target only allowed regions.
- The `DenyExternalAssumeRole` SCP pattern (blocking `sts:AssumeRole` from outside the org) has no impact on this design.

---

## Target Account Deployment Role Requirements

The pipeline does not create deployment roles in target accounts. Teams must provide existing roles that meet the following requirements. This section documents those requirements and provides example Terraform code.

### Trust Policy Requirements

The deployment role in each target account must trust the CodeBuild service role in the Automation Account. The trust policy should include an `aws:PrincipalOrgID` condition for defense-in-depth.

**Required trust policy:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<AUTOMATION_ACCT_ID>:role/CodeBuild-<project>-ServiceRole"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "o-<your-org-id>"
        }
      }
    }
  ]
}
```

**Note:** If multiple pipelines (projects) need to assume the same deployment role, the trust policy principal can reference multiple CodeBuild service roles, or a broader pattern using wildcards or a shared role.

### Permissions Requirements

The deployment role needs permissions to manage the specific AWS resources that the Terraform project creates. At minimum:

- **Read/write** on the resource types managed by Terraform (e.g., `ec2:*`, `rds:*`, `s3:*`, `lambda:*`).
- **iam:PassRole** if Terraform creates roles for services (e.g., Lambda execution roles).
- The deployment role does **not** need access to the S3 state bucket or DynamoDB — state I/O is handled by the CodeBuild service role in the Automation Account before the target account role is assumed.

**Recommended:** Attach a permission boundary to the deployment role, especially in PROD, to enforce a ceiling on what Terraform can do even if the role's policies are broad.

### Example Terraform Code (Target Account)

The following Terraform creates a deployment role suitable for use with the pipeline. This code would be applied by the account/security team in each target account.

```hcl
# target-account/deployment-role.tf

variable "automation_account_id" {
  description = "AWS Account ID of the Automation Account"
  type        = string
}

variable "org_id" {
  description = "AWS Organization ID"
  type        = string
}

variable "project_name" {
  description = "Name of the Terraform project (must match pipeline parameter)"
  type        = string
}

variable "environment" {
  description = "Environment name: dev or prod"
  type        = string
}

# Deployment role that the pipeline's CodeBuild assumes
resource "aws_iam_role" "terraform_deployment" {
  name = "TerraformDeploy-${var.project_name}-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.automation_account_id}:role/CodeBuild-${var.project_name}-ServiceRole"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = var.org_id
          }
        }
      }
    ]
  })

  # RECOMMENDED: permission boundary (especially for prod)
  # permissions_boundary = aws_iam_policy.deployment_boundary.arn

  max_session_duration = 7200  # 2 hours — adjust based on expected apply duration
}

# Attach policies for the resources Terraform manages
# Replace with actual resource-specific policies
resource "aws_iam_role_policy_attachment" "terraform_permissions" {
  role       = aws_iam_role.terraform_deployment.name
  policy_arn = aws_iam_policy.terraform_managed_resources.arn
}

# Example policy — scope to actual resources managed
resource "aws_iam_policy" "terraform_managed_resources" {
  name = "TerraformManagedResources-${var.project_name}-${var.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowManagedResourceTypes"
        Effect = "Allow"
        Action = [
          "ec2:*",
          "rds:*",
          "s3:*",
          "lambda:*",
          "iam:PassRole",
          "iam:GetRole",
          "iam:CreateRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:DeleteRole"
        ]
        Resource = "*"
        # RECOMMENDED: scope resources more tightly in production
      }
    ]
  })
}

# Example permission boundary (recommended for PROD)
resource "aws_iam_policy" "deployment_boundary" {
  name = "TerraformDeploymentBoundary-${var.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowStandardOperations"
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      },
      {
        Sid    = "DenyPrivilegeEscalation"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:CreateLoginProfile",
          "iam:UpdateLoginProfile",
          "iam:CreateAccessKey",
          "organizations:*",
          "account:*"
        ]
        Resource = "*"
      }
    ]
  })
}

# Output the role ARN for use as the pipeline parameter
output "deployment_role_arn" {
  description = "ARN to pass as dev_deployment_role_arn or prod_deployment_role_arn pipeline parameter"
  value       = aws_iam_role.terraform_deployment.arn
}
```

---

## State Management

### Architecture

Terraform state is stored in S3 within the Automation Account. This is consistent with the existing AFT pattern. **DynamoDB-based state locking is deprecated** — the MVP uses native S3 locking via `use_lockfile = true`, introduced in Terraform 1.10 and stabilized in Terraform 1.11.

```
Automation Account
├── S3 Bucket: <org>-terraform-state
│   ├── Versioning: enabled
│   ├── Encryption: SSE-KMS (or SSE-S3)
│   ├── Bucket Policy: deny unencrypted uploads, deny public access
│   ├── Lifecycle: (optional) noncurrent version expiry after 90 days
│   │
│   ├── <project-a>/dev/terraform.tfstate
│   ├── <project-a>/dev/terraform.tfstate.tflock    ← native S3 lock file
│   ├── <project-a>/prod/terraform.tfstate
│   ├── <project-a>/prod/terraform.tfstate.tflock
│   ├── <project-b>/dev/terraform.tfstate
│   └── ...
```

### Native S3 Locking (`use_lockfile`)

As of Terraform 1.11+, native S3 state locking replaces DynamoDB-based locking. The `dynamodb_table` argument is deprecated and will be removed in a future Terraform version.

**How it works:** When `use_lockfile = true`, Terraform creates a `.tflock` file in the same S3 location as the state file using S3 conditional writes (`If-None-Match` header). If the lock file already exists, the write fails, preventing concurrent operations. No additional AWS resources are required.

**Backend configuration:**

```hcl
terraform {
  backend "s3" {
    bucket         = "<org>-terraform-state"
    key            = "<project>/<env>/terraform.tfstate"
    region         = "ca-central-1"
    encrypt        = true
    use_lockfile   = true    # Native S3 locking — no DynamoDB needed
  }
}
```

**IAM requirements for locking:** The CodeBuild service role needs `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on the `.tflock` file path in addition to the state file path:

```
arn:aws:s3:::<bucket>/<project>/*/terraform.tfstate
arn:aws:s3:::<bucket>/<project>/*/terraform.tfstate.tflock
```

### Key Points

- There may be multiple state buckets for different projects or teams, but the principle is consistent: state lives in S3 in the Automation Account.
- The CodeBuild service role has S3 access in the Automation Account. Cross-account deployment roles in target accounts do **not** need state access — state I/O happens before the target account role is assumed.
- State files use project-and-environment-prefixed keys (`<project>/dev/`, `<project>/prod/`) so a single bucket can serve multiple pipelines.
- S3 versioning provides point-in-time recovery for state corruption.
- **No DynamoDB table is required.** This simplifies IAM policies, reduces infrastructure, and eliminates DynamoDB costs.

### Migration Note for Existing State

If existing Terraform projects currently use `dynamodb_table` for locking, migration to `use_lockfile` is safe and can be done incrementally. Both can be configured simultaneously during the transition — Terraform will acquire locks from both sources. Once confident, remove the `dynamodb_table` argument. See [HashiCorp's S3 backend documentation](https://developer.hashicorp.com/terraform/language/backend/s3) for migration details.

### Separation from AFT

AFT has its own state files and execution roles. The new CI/CD pipeline must use completely separate:

- S3 key prefixes (or a separate bucket entirely)
- IAM execution roles (never reuse `AWSAFTExecution` or `AWSAFTService`)

---

## Approval Workflow & Notifications

### MVP Flow

```
Pipeline reaches "Mandatory Approval" stage
    │
    ▼
CodePipeline publishes to SNS Topic: "<project>-pipeline-approvals"
    │
    ├──► Email (if sns_subscribers provided):
    │    reviewer receives pipeline name, stage, execution ID,
    │    and a direct link to the CodePipeline console approval page
    │
    └──► (No subscribers): Topic exists but no notifications are sent.
         Reviewer must check the CodePipeline console directly.

    ▼
Reviewer opens CodePipeline console (via email link or directly)
    │
    ├──► "Approve" (with optional comment)
    │    → Pipeline proceeds to Deploy PROD
    │    → Decision logged in CloudTrail
    │
    └──► "Reject" (with optional comment)
         → Pipeline stops
         → Decision logged in CloudTrail

If no action within 7 days → pipeline fails automatically
```

### SNS Topic Configuration

| Component | Detail |
|-----------|--------|
| Topic name | `<project_name>-pipeline-approvals` |
| Subscribers | Provided via `sns_subscribers` parameter. If empty, topic has no subscribers. |
| Subscriber type | Email addresses (MVP). Each receives a confirmation email they must accept. |
| Message format | JSON with `approval` key containing pipeline name, stage, review URL |
| Encryption | SSE-KMS (recommended) |

### Future Automation Path (Post-MVP)

The `PutApprovalResult` AWS API enables programmatic approvals. The post-MVP pattern:

1. SNS topic triggers a Lambda function on approval request.
2. Lambda evaluates conditions (e.g., all DEV tests passed, plan contains no deletions).
3. Lambda calls `codepipeline:PutApprovalResult` with `Approved` or `Rejected`.
4. Human remains the fallback for rejected or ambiguous cases.

This preserves the human-in-the-loop principle while automating routine approvals.

---

## Secrets Management

### Two Types of Secrets

The MVP distinguishes between two categories of secrets, stored in different locations for different purposes.

#### Automation Secrets (Automation Account)

Secrets that are specific to the pipeline automation and not related to any particular application or target account. These live in AWS Secrets Manager or Parameter Store in the **Automation Account**.

**Examples:** GitHub tokens (if needed beyond CodeStar Connection), shared pipeline configuration values, notification webhook URLs, pipeline-level API keys.

**Access:** The CodeBuild service role in the Automation Account has `secretsmanager:GetSecretValue` permission. These secrets are available to all stages of the pipeline.

**Buildspec integration:**

```yaml
env:
  secrets-manager:
    PIPELINE_API_KEY: "automation/pipeline/api-key:value"
  parameter-store:
    SHARED_CONFIG: "/automation/pipeline/config-value"
```

#### Application Secrets (Target Accounts)

Secrets that are specific to the Terraform project and its deployed infrastructure. These live in AWS Secrets Manager or Parameter Store in the **target account** (DEV or PROD) where they are used.

**Examples:** Database passwords, application API keys, certificate private keys, third-party service credentials — anything the deployed infrastructure needs.

**Access:** After the CodeBuild stage assumes the target account's deployment role, the Terraform code itself resolves these secrets at apply time using `aws_secretsmanager_secret_version` data sources or `aws_ssm_parameter` data sources. This keeps application secrets within their own account boundary — they never pass through the Automation Account.

**Terraform pattern:**

```hcl
# In the Terraform project code (not the pipeline)
data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = "myapp/db-password"
}

resource "aws_db_instance" "main" {
  # ...
  password = data.aws_secretsmanager_secret_version.db_password.secret_string
}
```

**Why two categories?** This separation follows least-privilege principles. Pipeline automation secrets are accessible only within the Automation Account. Application secrets are accessible only within their respective target accounts. Neither crosses the account boundary unnecessarily, and the pipeline never holds application credentials in its own environment variables.

CodeBuild natively masks secrets referenced via `secrets-manager` in buildspec — they will not appear in build logs.

---

## Source Control Integration

### CodeStar Connection

The pipeline uses an **AWS CodeStar Connection** to connect CodePipeline to GitHub. The `codestar_connection_arn` parameter controls behavior:

| Scenario | Behavior |
|----------|----------|
| `codestar_connection_arn` provided | Pipeline uses the existing connection. No new connection is created. |
| `codestar_connection_arn` empty or not provided | Pipeline creates a new CodeStar Connection automatically. The connection will need to be authorized via the AWS Console (one-time OAuth consent to the GitHub App). |

| Item | Detail |
|------|--------|
| Connection type | GitHub (via AWS Connector for GitHub App) |
| Authorization | GitHub App installed on the organization; one-time OAuth consent |
| Branch filter | Configurable via `github_branch` parameter (default: `main`) |
| Artifact format | Full clone (CodePipeline V2 default) |

### Repository Structure (Required Convention)

Developers must include the `cicd/` directory with the required shell scripts. The rest of the structure is at the developer's discretion.

```
<project-repo>/
├── main.tf                     # Root module (or any standard TF layout)
├── variables.tf
├── outputs.tf
├── providers.tf
├── backend.tf                  # S3 backend configuration
├── environments/
│   ├── dev.tfvars              # DEV-specific variable values
│   └── prod.tfvars             # PROD-specific variable values
├── modules/                    # (optional) Reusable Terraform modules
│   └── ...
├── cicd/                       # REQUIRED: pipeline-executed scripts
│   ├── prebuild/
│   │   └── main.sh             # Pre-build validation (developer-managed)
│   ├── dev/
│   │   └── smoke-test.sh       # DEV post-deploy tests (developer-managed)
│   └── prod/
│       └── smoke-test.sh       # PROD post-deploy tests (developer-managed)
└── tests/                      # (optional) additional test files
    └── ...
```

---

## Prerequisites

The following must be in place before MVP implementation begins.

| # | Prerequisite | Owner | Status |
|---|-------------|-------|--------|
| 1 | AWS Control Tower deployed with Automation Account and at least one target account enrolled | Platform team | ☐ |
| 2 | AFT operational in Automation Account (for baseline context) | Platform team | ☐ |
| 3 | GitHub organization with at least one IaC repository containing the `cicd/` directory structure | DevOps team | ☐ |
| 4 | S3 bucket for Terraform state created in Automation Account (versioned, encrypted) | Platform team | ☐ |
| 5 | Deployment roles created in target accounts (DEV and PROD) meeting the trust and permission requirements documented above | Account/Security team | ☐ |
| 6 | SCPs reviewed to confirm no blockers for cross-account `sts:AssumeRole` within the organization | Security team | ☐ |
| 7 | IaC runtime version confirmed (Terraform 1.11+ for native S3 locking, or OpenTofu equivalent) | DevOps team | ☐ |
| 8 | Agreed-upon pilot Terraform project with at least one deployable configuration | DevOps team | ☐ |
| 9 | (Optional) Existing CodeStar Connection ARN, if one already exists | DevOps team | ☐ |
| 10 | (Optional) Identified approvers for PROD deployments (email addresses for SNS) | Management | ☐ |

---

## Implementation Phases

### Phase 1 — Foundation

**Objective:** Establish the infrastructure that the pipeline runs on.

| Task | Detail |
|------|--------|
| Create S3 state bucket | Versioned, encrypted, bucket policy denying public access |
| Create IAM roles in Automation Account | CodePipeline service role, CodeBuild service role with cross-account AssumeRole permissions |
| Verify deployment roles in target accounts | Confirm trust policies and permissions meet requirements; test manual `sts:AssumeRole` |
| Create or verify CodeStar Connection | Authorize GitHub App if creating new; verify existing if using `codestar_connection_arn` |
| Create SNS topic | With optional subscribers if email addresses are provided |

**Exit criteria:** S3 state bucket is accessible. CodeBuild service role can assume deployment roles in both target accounts. CodeStar Connection is authorized. SNS topic exists.

### Phase 2 — Pipeline Assembly

**Objective:** Build the pipeline template and instantiate it for the pilot project.

| Task | Detail |
|------|--------|
| Create pipeline template (Terraform/CloudFormation) | Parameterized template that provisions CodePipeline V2, CodeBuild projects, and supporting resources |
| Instantiate pilot pipeline | Provide parameter values for the pilot Terraform project |
| Create CodeBuild projects | Pre-Build, Plan, Deploy (parameterized), Test (parameterized) |
| Add Manual Approval stages | Optional review (Stage 4) and mandatory approval (Stage 7) with SNS |
| Commit pipeline buildspec files | Four buildspec YAML files |
| Create developer `cicd/` scripts in pilot repo | `cicd/prebuild/main.sh`, `cicd/dev/smoke-test.sh`, `cicd/prod/smoke-test.sh` |

**Exit criteria:** Pipeline triggers on push to configured branch. All stages execute in sequence. Approval stages pause and send notifications (if subscribers configured).

### Phase 3 — Validation & Hardening

**Objective:** End-to-end testing and security validation.

| Task | Detail |
|------|--------|
| End-to-end pipeline run | Push a Terraform change that creates a simple resource (e.g., S3 bucket) through the full pipeline |
| Verify cross-account deployment | Confirm resources are created in DEV target account (Stage 5) and PROD target account (Stage 8) |
| Verify approval flow | Confirm SNS email is received (if subscribers exist), approval link works, CloudTrail logs the decision |
| Verify security scan visibility | Confirm scan results appear in CodeBuild Reports tab and plan output is visible in build logs |
| Verify test stages | Confirm `cicd/dev/smoke-test.sh` and `cicd/prod/smoke-test.sh` execute with target account credentials |
| Verify state management | Confirm state file is written to S3, versioning works, `.tflock` file is created and released |
| Verify pipeline failure handling | Trigger a deliberate failure (e.g., non-zero exit from `main.sh`, failed smoke test) and confirm pipeline stops at the correct stage |
| Verify SCP compatibility | Confirm pipeline operations succeed within Control Tower guardrails |
| Verify parameterization | Confirm that changing `github_branch`, deployment role ARNs, or compute type works as expected |
| Security review | Review IAM policies, trust policies, and CloudTrail logs with the security team |
| Document runbook | Operational procedures for pipeline failures, approval process, onboarding new projects, and common troubleshooting |

**Exit criteria:** At least three successful end-to-end pipeline runs. Security team sign-off. Runbook completed.

### Phase 4 — Handoff

**Objective:** Transition to operational ownership.

| Task | Detail |
|------|--------|
| Team walkthrough | Demo the pipeline to the architecture and project team |
| Knowledge transfer | Pipeline parameterization, `cicd/` script authoring, deployment role management, state management, approval procedures |
| Publish onboarding guide | Document how to provision a new pipeline for a new Terraform project using the template parameters |
| Retrospective | Identify what worked, what didn't, and what should change for the next pipeline |

---

## Cost Estimate

### Monthly Operating Cost (Single Pipeline, Moderate Use)

| Component | Unit Cost | Estimated Usage | Monthly Cost |
|-----------|----------|-----------------|-------------|
| CodePipeline V2 | $0.002/action-minute | ~500 action-minutes | ~$1.00 |
| CodeBuild (general1.small) | $0.005/build-minute | ~1,000 build-minutes | ~$5.00 |
| S3 (state + artifacts) | Standard S3 pricing | < 1 GB | ~$0.03 |
| SNS (email notifications) | First 1,000 free | < 100 messages | $0.00 |
| CloudWatch Logs | $0.50/GB ingested | ~0.5 GB logs | ~$0.25 |
| Secrets Manager (automation) | $0.40/secret/month | ~3 secrets | ~$1.20 |
| **Total estimated (per pipeline)** | | | **~$7–$12/month** |

### Scaling Notes

- Each additional Terraform project adds a new pipeline instance at roughly the same cost.
- 10 active pipelines with moderate use: estimated $50–$80/month.
- The free tier covers 100 CodePipeline action-minutes and 100 CodeBuild build-minutes per month.
- No per-user, per-seat, or subscription fees.
- **DynamoDB costs eliminated** — native S3 locking has no additional cost beyond standard S3 operations.
- Application secrets are in the target accounts and are not a pipeline cost.

---

## Success Criteria

The MVP is considered successful when all of the following are met:

| # | Criterion | Validation Method |
|---|-----------|-------------------|
| 1 | Pipeline triggers automatically on push to the configured branch | Observe pipeline execution after a commit |
| 2 | Pre-build stage executes `cicd/prebuild/main.sh` and stops on non-zero exit | Push a deliberately failing script and verify pipeline stops |
| 3 | Plan stage generates a plan and security scan results are visible in CodeBuild Reports | Inspect CodeBuild Reports tab and build logs |
| 4 | Deploy DEV creates resources in the DEV target account using the configured deployment role | Verify resources exist in DEV account |
| 5 | Test DEV executes `cicd/dev/smoke-test.sh` with DEV account credentials | Review test stage logs showing script output |
| 6 | Mandatory approval sends notification and blocks until reviewer acts | Receive email (if subscribers configured), approve in console |
| 7 | Deploy PROD creates resources in the PROD target account using the configured deployment role | Verify resources exist in PROD account |
| 8 | Test PROD executes `cicd/prod/smoke-test.sh` with PROD account credentials | Review test stage logs |
| 9 | Rejection at approval stage stops the pipeline | Reject and verify PROD deploy does not execute |
| 10 | All STS AssumeRole calls are logged in CloudTrail with traceable session names | Query CloudTrail for `AssumeRole` events |
| 11 | No stored long-lived credentials anywhere | Audit: no AWS access keys in GitHub, buildspecs, or env vars |
| 12 | State file is written to S3 with versioning and native S3 locking is functional | Verify `.tflock` file creation/release in S3 |
| 13 | Pipeline parameters work correctly | Change branch, deployment role, or compute type and verify behavior |
| 14 | A second pipeline can be provisioned from the template for a different project | Instantiate with different parameters and run end-to-end |

---

## Assumptions & Constraints

### Assumptions

1. AWS Control Tower is deployed and target accounts are enrolled.
2. The team has administrative access to the Automation Account for provisioning pipeline infrastructure.
3. GitHub organization allows installation of the AWS CodeStar Connection GitHub App.
4. Deployment roles already exist (or will be created by the account/security team) in target accounts before the pipeline is provisioned.
5. At least one team member is designated as a PROD deployment approver (if SNS subscribers are provided).
6. The Automation Account is the agreed-upon location for CI/CD infrastructure, consistent with the AFT deployment pattern.
7. Each Terraform project uses either Terraform (1.11+) or OpenTofu — not both simultaneously in the same pipeline.
8. Developers will populate the `cicd/` directory with working shell scripts before the pipeline is activated.

### Constraints

1. Each pipeline deploys to exactly two target accounts (DEV and PROD). Additional environments require extending the pipeline template.
2. Human approval is via the CodePipeline console (email link if subscribers configured). In-Slack or in-Teams approval is post-MVP.
3. Rollback is manual (revert the commit and re-run the pipeline). Automated rollback is post-MVP.
4. The 7-day approval timeout is a CodePipeline default.
5. Terraform version must be 1.11+ to use native S3 locking. Older versions require the deprecated DynamoDB approach.
6. Tool installation (tflint, checkov, etc.) happens inline in developer scripts — this adds 30–90 seconds to build time compared to pre-baked custom Docker images.
7. The pipeline does not create or manage deployment roles in target accounts — this is a prerequisite.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **SCP blocks cross-account AssumeRole** | Medium | High — pipeline cannot deploy | Pre-validate SCPs in Phase 1; ensure `aws:PrincipalOrgID` condition matches. Engage security team early. |
| **Deployment role missing or misconfigured** | Medium | High — pipeline cannot deploy | Provide documented requirements and example Terraform code. Validate role trust policy in Phase 1. |
| **CodeBuild timeout on large Terraform applies** | Low | Medium — pipeline fails mid-apply | Set CodeBuild timeout to 60 minutes (default 60, max 480). Configurable via `codebuild_compute_type`. |
| **State file corruption** | Low | High — Terraform cannot plan or apply | S3 versioning enables recovery. Native S3 locking prevents concurrent writes. Document recovery procedure in runbook. |
| **Approval bottleneck (reviewer unavailable)** | Medium | Medium — pipeline stalls for days | Provide multiple email addresses in `sns_subscribers`. Post-MVP: add Slack notifications and auto-reminders. |
| **Secrets exposure in build logs** | Low | High — credential leak | CodeBuild masks `secrets-manager` references by default. Verify masking in Phase 3 testing. Instruct developers to never `echo` secret values. |
| **Developer shell scripts fail or are missing** | Medium | Medium — pipeline fails at pre-build or test stage | Document the `cicd/` convention clearly. Include example scripts in the onboarding guide. Pipeline fails gracefully (non-zero exit → stage failure). |
| **Inline tool installation adds build time** | High | Low — slower builds (30–90 sec) | Acceptable for MVP. Post-MVP: custom Docker images eliminate install overhead. |
| **AFT and CI/CD pipeline interference** | Low | Medium — state or IAM conflicts | Strict separation of state prefixes and IAM roles. Document boundary in runbook. |
| **Terraform version incompatible with `use_lockfile`** | Low | Medium — locking fails | Require Terraform 1.11+ (or OpenTofu equivalent). Validate version in Phase 1. |

---

## Post-MVP Enhancements

The following are explicitly out of scope for the MVP but form the natural roadmap for subsequent iterations.

| Enhancement | Description | Priority |
|------------|-------------|----------|
| **Custom CodeBuild Docker images** | Pre-baked images in ECR with Terraform/OpenTofu, tflint, checkov, Python, jq — eliminates inline install time | High |
| **Automated approval (Lambda)** | Lambda evaluates conditions and calls `PutApprovalResult` to auto-approve safe changes | High |
| **Slack notifications & approval** | AWS Chatbot for zero-code Slack notifications; Lambda + API Gateway for approve-from-Slack | High |
| **Pipeline template module** | Terraform module that provisions a complete pipeline from parameters — enables self-service | High |
| **GitHub PR plan comments** | Lambda triggered by CodeBuild to post `terraform plan` output as a PR comment | Medium |
| **Drift detection** | Scheduled CodeBuild job running `terraform plan` and alerting via SNS if drift is detected | Medium |
| **Cost estimation (Infracost)** | Developers can add Infracost to `cicd/prebuild/main.sh`, or it can be a standard plan-stage step | Medium |
| **Policy-as-code (OPA/conftest)** | Evaluate Terraform plans against custom OPA policies in the plan stage | Medium |
| **Feature branch pipelines** | Trigger plan-only pipelines on feature branch pushes for PR review | Medium |
| **Additional environment stages** | Extend the template to support staging, QA, or other intermediate environments | Medium |
| **Pipeline dashboard** | CloudWatch dashboard aggregating pipeline success rates, durations, and approval wait times | Low |
| **Rollback automation** | On failure, automatically apply the previous successful state version | Low |

---

## Appendix: Quick Reference

### Key AWS Resources (Per Pipeline Instance)

| Resource | Account | Name Pattern |
|----------|---------|--------------|
| CodePipeline | Automation | `<project_name>-pipeline` |
| CodeBuild (Pre-Build) | Automation | `<project_name>-prebuild` |
| CodeBuild (Plan) | Automation | `<project_name>-plan` |
| CodeBuild (Deploy) | Automation | `<project_name>-deploy` |
| CodeBuild (Test) | Automation | `<project_name>-test` |
| SNS Approval Topic | Automation | `<project_name>-pipeline-approvals` |
| CodeBuild Service Role | Automation | `CodeBuild-<project_name>-ServiceRole` |
| CodePipeline Service Role | Automation | `CodePipeline-<project_name>-ServiceRole` |
| S3 State Bucket | Automation | `<org>-terraform-state` (shared) |
| CodeStar Connection | Automation | Existing or auto-created (shared) |
| Deployment Role (DEV) | DEV Target Account | Configurable (e.g., `TerraformDeploy-<project>-dev`) |
| Deployment Role (PROD) | PROD Target Account | Configurable (e.g., `TerraformDeploy-<project>-prod`) |

### Key Decisions Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| CI/CD technology | AWS CodePipeline + CodeBuild | Cross-account security, SCP compatibility, data residency, cost |
| Pipeline-to-project ratio | 1:1 | Isolation, simple configuration, small blast radius |
| IaC runtime | Terraform or OpenTofu (mutually exclusive) | Avoid state compatibility risks from mixing runtimes |
| State locking | Native S3 (`use_lockfile = true`) | DynamoDB locking deprecated in Terraform 1.11+; S3 native is simpler and cheaper |
| State backend | S3 in Automation Account | Consistent with AFT, centralized, versioned |
| Cross-account auth | IAM role assumption (first-hop) | No role chaining limit, no external trust |
| Deployment roles | Pre-existing, passed as parameters | Separation of responsibility; pipeline team manages orchestration, account team manages permissions |
| Approval mechanism | Manual Approval + SNS (optional subscribers) | Human click-ops (MVP), API-automatable (future) |
| Secrets | Two types: Automation (automation account) + Application (target accounts) | Least-privilege; secrets stay within their account boundary |
| CodeBuild images | Standard managed images + inline install | No custom Docker image lifecycle in MVP; developers control their tools |
| Developer scripts | Standardized paths (`cicd/prebuild/main.sh`, `cicd/{env}/smoke-test.sh`) | Developers own validation content; pipeline owns orchestration |
| CodeStar Connection | Optional parameter | Reuse existing or auto-create; avoids duplicate connections |
| SNS subscribers | Optional parameter | Flexible — topic always exists for future use even if no subscribers initially |
| Branch trigger | Configurable, default `main` | Supports team-specific branching strategies |

### Sources

- [Terraform S3 Backend Documentation](https://developer.hashicorp.com/terraform/language/backend/s3) — Native S3 locking (`use_lockfile`), DynamoDB deprecation
- [Deprecation of dynamodb_table in Terraform S3 Backend — HashiCorp Discuss](https://discuss.hashicorp.com/t/deprecation-of-dynamodb-table-in-terraform-s3-backend/77060)
- [S3-Native State Locking: No More DynamoDB for Terraform State](https://medium.com/aws-specialists/dynamodb-not-needed-for-terraform-state-locking-in-s3-anymore-29a8054fc0e9)
- [AWS CodePipeline Pricing](https://aws.amazon.com/codepipeline/pricing/)
- [AWS CodeBuild Pricing](https://aws.amazon.com/codebuild/pricing/)
- [AWS CodePipeline: Add Manual Approval Action](https://docs.aws.amazon.com/codepipeline/latest/userguide/approvals.html)
