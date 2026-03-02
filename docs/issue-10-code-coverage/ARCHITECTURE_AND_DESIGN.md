# Architecture and Design: CodeBuild Code Coverage Reporting for Checkov

## Overview

This document covers the design of the Checkov code coverage reporting enhancement to the
`terraform-pipelines` module (Issue #10). The change is confined to a single buildspec file:
`modules/core/buildspecs/plan.yml`.

When a Plan stage runs with `ENABLE_SECURITY_SCAN=true`, the updated buildspec:

1. Invokes Checkov with dual output (`cli` + `json`) to produce a machine-readable results file
2. Runs an inline Python converter to transform the Checkov JSON into a Cobertura XML coverage report
3. Lets CodeBuild automatically upload the Cobertura file to a report group visible in the console

The CodeBuild service role IAM policy already contains all required report permissions
(`CodeBuildReports` statement in `modules/core/iam.tf`). No new Terraform resources are needed
for MVP. No consumer-facing variables change.

## Component Diagram

```
plan.yml — buildspec execution (ENABLE_SECURITY_SCAN=true path)
═══════════════════════════════════════════════════════════════════════════════════

  INSTALL PHASE
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  pip3 install checkov      (only when ENABLE_SECURITY_SCAN=true)            │
  └─────────────────────────────────────────────────────────────────────────────┘
                │
                ▼
  BUILD PHASE
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  [1] terraform init + terraform plan -out=tfplan                            │
  │                                                                             │
  │  [2] terraform show -json tfplan  ──────────────► tfplan.json               │
  │                                                                             │
  │  [3] mkdir -p /tmp/checkov                                                  │
  │      set +e                       ◄── suspend abort-on-error                │
  │      checkov -f tfplan.json                                                 │
  │        --output cli               ──────────────► stdout (CloudWatch Logs)  │
  │        --output json                                                        │
  │        --output-file-path /tmp/checkov  ────────► /tmp/checkov/             │
  │                                                   results_json.json         │
  │      CHECKOV_EXIT=$?              ◄── exit code captured                    │
  │      set -e                       ◄── restore abort-on-error                │
  │                                                                             │
  │  [4] python3 (inline heredoc converter)                                     │
  │        reads  /tmp/checkov/results_json.json                                │
  │        writes /tmp/checkov/checkov-cobertura.xml                            │
  │        prints coverage summary to stdout (CloudWatch Logs)                  │
  │                                                                             │
  │  [5] [ $CHECKOV_EXIT -eq 0 ] || exit $CHECKOV_EXIT                         │
  │        ▲── hard-fail / soft-fail behaviour preserved; re-raised AFTER       │
  │            converter so report is always generated and uploaded              │
  │                                                                             │
  │  [6] rm -f tfplan.json            ◄── only reached on success/soft-fail     │
  └─────────────────────────────────────────────────────────────────────────────┘
                │
                ▼
  POST_BUILD PHASE
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  rm -f _pipeline_override.tf      (always runs, even after build failure)   │
  └─────────────────────────────────────────────────────────────────────────────┘

  ─ ─ ─ ─ ─ ─ CODEBUILD FRAMEWORK (outside phase execution) ─ ─ ─ ─ ─ ─ ─ ─ ─

  ╔══════════════════════════════════════════════════════════════════════════╗
  ║  reports: section (static buildspec YAML — evaluated by CodeBuild        ║
  ║           automatically after all phases complete)                       ║
  ║                                                                          ║
  ║    checkov-security:                                                     ║
  ║      files: ["/tmp/checkov/checkov-cobertura.xml"]                       ║
  ║      file-format: COBERTURAXML                                           ║
  ╚══════════════════════════════════════════════════════════════════════════╝
                │
                │  CodeBuild reads file, calls report upload APIs
                ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  CodeBuild Report Group (auto-created on first upload)                  │
  │  Names:  {project_name}-plan-dev-checkov-security                       │
  │          {project_name}-plan-prod-checkov-security                      │
  │  Type:   CODE_COVERAGE                                                  │
  │  Visible: CodeBuild console → Build → Reports tab                       │
  └─────────────────────────────────────────────────────────────────────────┘
                │
                │  IAM permission chain
                ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  CodeBuild-{project_name}-ServiceRole                                   │
  │    └── CodeBuildReports policy statement (modules/core/iam.tf)          │
  │          Actions: CreateReportGroup, CreateReport, UpdateReport,         │
  │                   BatchPutTestCases, BatchPutCodeCoverages               │
  │          Resource: arn:aws:codebuild:{region}:{account_id}:             │
  │                    report-group/{project_name}-*                         │
  └─────────────────────────────────────────────────────────────────────────┘

─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ENABLE_SECURITY_SCAN=false path ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

  BUILD PHASE: security scan block is skipped entirely (no Checkov, no converter,
               no /tmp/checkov/ directory created)

  reports: section: CodeBuild attempts to locate the Cobertura file, finds it
               absent, emits a WARNING to CloudWatch Logs, and continues.
               The build does NOT fail. No report is uploaded for that run.
```

## Data Flow

### ENABLE_SECURITY_SCAN=true (normal path)

1. **Terraform plan** produces `tfplan` binary artifact (no change to this step)
2. `terraform show -json tfplan` converts the binary plan to `tfplan.json` in the working directory
3. `mkdir -p /tmp/checkov` ensures the output directory exists for Checkov
4. `set +e` suspends `pipefail` abort-on-error so Checkov's non-zero exit code does not abort
   the buildspec before the converter runs
5. Checkov scans `tfplan.json` with `--output cli --output json --output-file-path /tmp/checkov`:
   - CLI output goes to stdout, captured by CodeBuild to CloudWatch Logs (unchanged build log)
   - Structured JSON is written to `/tmp/checkov/results_json.json`
6. `CHECKOV_EXIT=$?` captures the Checkov exit code (0 = all passed, 1 = findings or error)
7. `set -e` restores abort-on-error for the remainder of the buildspec
8. The Python converter reads `/tmp/checkov/results_json.json` and groups checks by Terraform
   resource:
   - Each resource → one `<class>` element in the Cobertura XML
   - Each check on a resource → one `<line>` with `hits="1"` (passed) or `hits="0"` (failed)
   - Skipped checks are excluded from both numerator and denominator
   - Overall `line-rate` = `passed / (passed + failed)`, defaulting to `1.0` when total is zero
   - Converter prints a summary (`Coverage: X/Y checks passed (Z%)`) to stdout for CloudWatch
9. Converter writes `/tmp/checkov/checkov-cobertura.xml`
10. `[ "${CHECKOV_EXIT}" -eq 0 ] || exit "${CHECKOV_EXIT}"` re-raises the captured exit code.
    This fires AFTER the converter so the report is always uploaded regardless of pass/fail.
    The existing hard-fail (PROD) / soft-fail (DEV with `checkov_soft_fail=true`) behaviour
    is unchanged.
11. `rm -f tfplan.json` cleans up the JSON plan. Note: this line is only reached on success or
    soft-fail; a hard-failing PROD build exits at step 10 and `tfplan.json` is not deleted
    (ephemeral build container, no artifact export — no persistent exposure).
12. CodeBuild reads the `reports:` section after all phases complete and uploads
    `/tmp/checkov/checkov-cobertura.xml` to the report group using the service role credentials
13. The report group (`{project_name}-plan-{env}-checkov-security`) is auto-created on first
    upload; subsequent uploads append to the existing group's run history

### ENABLE_SECURITY_SCAN=false (skip path)

1. Build phase skips the entire security scan block — Checkov is not installed, `/tmp/checkov/`
   is never created, no converter runs
2. The `reports:` section is always present in the buildspec (static YAML, cannot be conditional)
3. CodeBuild evaluates the `reports:` section, finds `/tmp/checkov/checkov-cobertura.xml` absent,
   emits a non-fatal warning to CloudWatch Logs, and continues
4. The build completes normally; no report is uploaded for this run

## Component Inventory

| # | Component | Type / Technology | Purpose |
|---|---|---|---|
| 1 | `modules/core/buildspecs/plan.yml` | YAML buildspec | Primary change target — Checkov command, Python converter, `reports:` section |
| 2 | Checkov CLI | Python package (`pip3 install checkov`) | Security scanner; installed in install phase when `ENABLE_SECURITY_SCAN=true` |
| 3 | Cobertura XML converter | Inline Python 3 heredoc (`python3 << 'PYEOF'`) | Transforms `/tmp/checkov/results_json.json` → `/tmp/checkov/checkov-cobertura.xml` |
| 4 | `/tmp/checkov/` directory | Ephemeral build container directory | Working space for Checkov outputs; outside `$CODEBUILD_SRC_DIR`; never exported as artifact |
| 5 | `/tmp/checkov/results_json.json` | JSON file (Checkov output) | Intermediate file; consumed by converter; ephemeral |
| 6 | `/tmp/checkov/checkov-cobertura.xml` | Cobertura XML file (converter output) | Consumed by CodeBuild `reports:` upload; ephemeral |
| 7 | `reports:` section in `plan.yml` | Static YAML buildspec directive | Instructs CodeBuild to locate and upload the Cobertura file after phases complete |
| 8 | `{project_name}-plan-dev-checkov-security` | AWS CodeBuild Report Group (auto-created) | Stores DEV coverage reports; created by CodeBuild on first upload |
| 9 | `{project_name}-plan-prod-checkov-security` | AWS CodeBuild Report Group (auto-created) | Stores PROD coverage reports; created by CodeBuild on first upload |
| 10 | `CodeBuildReports` IAM statement | Policy statement in `modules/core/iam.tf` | Already present; grants 5 required report actions scoped to `{project_name}-*` |

## Security Model

### Encryption

Checkov report data is uploaded to CodeBuild's internal report storage. Auto-created report groups
use SSE-S3 encryption by default (not CMK). This is consistent with the existing module-wide policy
of deferring CMK encryption to a post-MVP phase (see `main.tf` Checkov skips for `CKV_AWS_147`
and `CKV_AWS_158`).

Consumers running the AWS Config rule `CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST` will see
auto-created report groups flagged as NON_COMPLIANT until an explicit `aws_codebuild_report_group`
resource with a KMS key is added post-MVP (see SEC-5 in Well-Architected Review).

The `/tmp/checkov/` files are ephemeral within the build container. They are not exported as
pipeline artifacts and are not accessible outside the build execution. `tfplan.json` is deleted
immediately after the scan on the success/soft-fail path (see Data Flow step 11 for the hard-fail
edge case; the build container is discarded regardless).

### Access Control

The CodeBuild service role (`CodeBuild-{project_name}-ServiceRole`) is granted report
permissions via the existing `CodeBuildReports` IAM statement in `modules/core/iam.tf`:

```
Actions:  codebuild:CreateReportGroup
          codebuild:CreateReport
          codebuild:UpdateReport
          codebuild:BatchPutTestCases
          codebuild:BatchPutCodeCoverages

Resource: arn:aws:codebuild:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:report-group/${var.project_name}-*
```

The wildcard `{project_name}-*` covers the two auto-created report groups
(`{project_name}-plan-dev-checkov-security`, `{project_name}-plan-prod-checkov-security`)
while remaining scoped to a single project. No cross-project access is possible.

`BatchPutTestCases` is included in the statement alongside `BatchPutCodeCoverages`. The action is
required by the AWS-recommended policy pattern for both report types and enables a future JUnit
test report alongside the coverage report without an IAM change (see Design Decision #15).

### Audit and Logging

- Checkov CLI output (findings list) continues to be written to CloudWatch Logs via the existing
  log group (`/codebuild/{project_name}-plan-{env}`)
- The Python converter prints a coverage summary line to stdout, also captured in CloudWatch Logs
- CodeBuild report upload events are recorded in CloudTrail under the
  `codebuild:UpdateReport` and `codebuild:BatchPutCodeCoverages` API calls
- When `ENABLE_SECURITY_SCAN=false`, CodeBuild logs a warning about the missing report file in
  the build log; this is non-fatal and distinguishable from a converter failure

## File Organization

```
modules/core/
├── buildspecs/
│   └── plan.yml          # MODIFIED — Checkov JSON output, Python converter heredoc, reports: section
├── iam.tf                # UNCHANGED — CodeBuildReports statement already present
├── main.tf               # UNCHANGED — no new CodeBuild or report group resources for MVP
├── variables.tf          # UNCHANGED — no new variables
└── outputs.tf            # UNCHANGED — no new outputs

docs/issue-10-code-coverage/
├── PROBLEM-STATEMENT.md  # Background and gap analysis
├── MVP.md                # Technical design reference
└── ARCHITECTURE_AND_DESIGN.md  # This document
```

## Design Decisions

| # | Decision | Rationale | Alternatives Considered |
|---|---|---|---|
| 1 | Use Cobertura XML (code coverage report) rather than JUnit XML (test report) | The issue explicitly requests "code coverage reports." CodeBuild has two distinct report types: test reports (JUnit XML) and coverage reports (Cobertura, JaCoCo, etc.). Only coverage reports show a line-rate percentage metric and trend graph. | **JUnit XML (rejected):** Checkov natively outputs JUnit XML via `--output junitxml`, requiring no converter. However, JUnit maps to CodeBuild Test Reports which show only pass/fail counts — no coverage percentage or trend chart. The issue intent and "code coverage" framing make Cobertura the correct choice. |
| 2 | Single flat `<package name="terraform-plan">` in the Cobertura XML | Simplest converter logic. CodeBuild console still shows per-resource (`<class>`) coverage. Grouping by resource type adds complexity without improving the console view for this use case. | Grouping `<class>` elements under multiple `<package>` elements by Terraform resource type (e.g., `aws_s3`) was considered. It adds ~10 lines of converter code for marginal console improvement. Deferred to post-MVP. |
| 3 | One `<line>` element per check per resource (full granularity) | Enables drill-down to individual check IDs in the CodeBuild console. | Aggregating to one line per resource (single hit=0/1 per resource) was considered. This would lose all check-level visibility, defeating the goal of per-check audit trail. Rejected. |
| 4 | Inline Python heredoc rather than a standalone `.py` script file | MVP changes exactly one file (`plan.yml`). The converter is ~35 lines and readable inline. | A separate `modules/core/buildspecs/checkov-to-cobertura.py` file would make unit testing easier. Extraction is straightforward as a post-MVP refactor when automated testing of the converter is needed. |
| 5 | Auto-created CodeBuild report group (no `aws_codebuild_report_group` Terraform resource) | CodeBuild creates the report group automatically on first upload. The auto-created name (`{project_name}-plan-{env}-checkov-security`) matches the existing IAM wildcard. | **Explicit `aws_codebuild_report_group` resource (deferred):** Required for S3 export, KMS encryption, custom retention, and explicit lifecycle management. Environments enforcing `CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST` AWS Config rule will need this post-MVP. Auto-creation covers MVP with zero new Terraform resources. |
| 6 | `set +e / set -e` exit code capture rather than immediate abort | Checkov's exit code must be re-raised _after_ the converter runs, not before. Without `set +e`, `set -euo pipefail` would abort the buildspec immediately on a failed scan, preventing the Cobertura XML from being generated and uploaded. | **Subshell approach (`(checkov ...; echo $?) > exit_code`):** More isolated but less readable in a YAML heredoc context. **`|| true` with separate check:** Would silently swallow non-zero exits unless carefully reconstructed. `set +e / set -e` with an explicit capture variable is the most explicit and readable pattern for this buildspec style. |
| 7 | `--output cli --output json` in a single Checkov invocation | One invocation produces both human-readable console output (unchanged build log) and the structured JSON file. | Running Checkov twice (once for CLI, once for JSON) would double scan time and is inconsistent — results could theoretically differ if the plan changes between runs. Single invocation is correct. |
| 8 | `/tmp/checkov/` as the converter working directory | Ephemeral and isolated from `$CODEBUILD_SRC_DIR`. Files in `/tmp` are never accidentally included in pipeline artifacts. The directory is created with `mkdir -p` before Checkov runs. | Using `$CODEBUILD_SRC_DIR/checkov-output/` was considered. Files there would be visible in the pipeline artifact context, risking accidental inclusion. `/tmp` provides cleaner isolation. |
| 9 | `reports:` section always present (static YAML) | Buildspec YAML is static — it cannot include conditionals. When `ENABLE_SECURITY_SCAN=false`, the Cobertura file will not exist; CodeBuild emits a warning but does not fail the build. | **`templatefile()` in Terraform to conditionally include `reports:` block:** Would add Terraform complexity and a diff-to-understand template. The non-fatal warning CodeBuild emits when the file is absent is acceptable and documented (see Data Flow, OE-2). |
| 10 | Always generate and upload the report regardless of Checkov pass/fail | The converter runs before the exit code is re-raised. Even a hard-failing PROD plan scan produces a report — operators can see exactly which checks failed in the CodeBuild console. | Aborting on Checkov failure before running the converter would result in no report for failed scans, the runs where the report is most valuable. This alternative was not seriously considered once the `set +e` pattern was chosen. |
| 11 | Skipped checks excluded from coverage calculation | `skipped_checks` represent intentional suppressions. Including them as "covered" would inflate the percentage and misrepresent security posture. | Including skipped checks as passing (hits=1) was considered but rejected as it would make coverage meaningless in repos with broad suppressions. Including them as a third category (partial credit) is a post-MVP option. |
| 12 | `line_rate = 1.0` when total checks is zero | If Checkov returns an empty result (no checks apply to the plan), division by zero must be avoided. | Defaulting to `0.0` (0% coverage) when there are no checks was considered but is misleading — zero checks means zero failures, which should not penalise a project. `1.0` (100%) is the mathematically safe and semantically correct default. |
| 13 | No new module input variables | The feature is activated by the existing `enable_security_scan` flag. | A separate `enable_coverage_report` variable (default `true`) was considered. It would allow Checkov to run without producing a report — creating an inconsistent state with no clear use case. Coupling report generation to `enable_security_scan` is cleaner. |
| 14 | IAM scoped to `{project_name}-*` wildcard (not explicit report group ARN) | The report group ARN is not known at Terraform apply time — CodeBuild auto-creates it on first build. An explicit ARN would require either a chicken-and-egg dependency or a `aws_codebuild_report_group` resource. | **Explicit ARN via `aws_codebuild_report_group`:** Provides tighter least-privilege but requires the explicit resource (out of scope for MVP). The `{project_name}-*` wildcard is already scoped to a single project and matches the pattern recommended in AWS documentation. |
| 15 | `BatchPutTestCases` included in the `CodeBuildReports` IAM statement | The statement pre-existed with both coverage and test case actions, following the AWS recommended policy for report-enabled CodeBuild projects. | Removing `BatchPutTestCases` to strict minimum for this feature would require a future IAM change when a JUnit test report is added (post-MVP). The permission is harmless without a JUnit `reports:` entry in the buildspec. |

## Deployment Workflow

This is a module change delivered via the standard development and testing flow:

```
1. Modify modules/core/buildspecs/plan.yml
   ├── Add --output cli --output json --output-file-path /tmp/checkov to Checkov command
   ├── Wrap Checkov with set +e / CHECKOV_EXIT=$? / set -e
   ├── Add inline Python converter heredoc
   ├── Add [ $CHECKOV_EXIT -eq 0 ] || exit $CHECKOV_EXIT re-raise
   └── Add top-level reports: section with COBERTURAXML entry

2. bash tests/test-terraform.sh --skip-security   (fast: fmt + validate)
   └── Confirms YAML syntax and Terraform module validation pass

3. bash tests/test-terraform.sh                    (full: all 7 steps)
   └── Runs Checkov and Trivy against the module itself

4. bash tests/test-terraform.sh --deploy default  (E2E: requires AWS creds + test tfvars)
   └── After pipeline runs: CodeBuild console → {project_name}-plan-dev project
       → Reports tab → confirm report named {project_name}-plan-dev-checkov-security
       → confirm line coverage percentage shown
       → confirm per-resource class drill-down available

5. Soft-fail validation: deploy with checkov_soft_fail = true
   └── Plan stage completes despite findings; report uploaded

6. Security scan disabled validation: deploy with enable_security_scan = false
   └── Plan stage completes; no report upload errors in build log

7. Commit to development/codecoverage branch
8. Open PR to main
   └── Add note to module README per SEC-5: auto-created report groups use SSE-S3,
       not CMK. Consumers enforcing CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST Config
       rule must add aws_codebuild_report_group resource post-MVP.
```

The `reports:` section in the buildspec takes effect on the next pipeline execution after the
module is deployed. No manual report group creation is needed.

## Dependency Graph

```
CodeBuild Report Group (auto-created on first upload)
    └── requires: /tmp/checkov/checkov-cobertura.xml
        └── generated by: Python converter (inline heredoc)
            └── requires: /tmp/checkov/results_json.json
                └── written by: checkov --output json --output-file-path /tmp/checkov
                    └── requires: tfplan.json
                        └── generated by: terraform show -json tfplan
                            └── requires: ENABLE_SECURITY_SCAN=true
                                └── controlled by: enable_security_scan module variable (default: true)

IAM permissions (CodeBuildReports statement in iam.tf)
    └── already present — no new dependency introduced by this feature

CodeBuild project name → report group name (auto-created naming convention)
    {project_name}-plan-dev   + buildspec key "checkov-security"
        → {project_name}-plan-dev-checkov-security
    {project_name}-plan-prod  + buildspec key "checkov-security"
        → {project_name}-plan-prod-checkov-security
    Both match IAM wildcard: {project_name}-*  ✓
```

## Out of Scope

| Item | Rationale |
|---|---|
| `aws_codebuild_report_group` Terraform resource | Auto-creation covers MVP. Explicit lifecycle (S3 export, custom retention, KMS) is post-MVP. |
| KMS CMK encryption for report group | Module-wide CMK deferral policy applies. Post-MVP. Required for `CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST` Config rule compliance. |
| Coverage threshold gate (`checkov_coverage_threshold`) | Failing the build on low coverage % requires a new variable and build logic. Post-MVP. |
| Skipped checks in Cobertura output | Intentional suppressions distort the coverage metric. Post-MVP decision. |
| JUnit XML test report | Parallel test report alongside coverage report. Post-MVP. `BatchPutTestCases` IAM action already present. |
| Checkov in non-plan buildspecs | Only Plan stages run Checkov. Out of scope for this feature. |
| CodeBuild report group sharing or cross-account visibility | Reports are scoped to the Automation Account. No cross-account report access needed. |
| S3 export of raw report data | Default 30-day CodeBuild retention covers MVP. Long-term retention via S3 export is post-MVP. |

---

## Well-Architected Review

Assessment against the six AWS Well-Architected Framework pillars. Conducted against `MVP.md`,
`PROBLEM-STATEMENT.md`, and this document, grounded in AWS documentation references below.

**Summary:**

| Pillar | Findings | Already Addressed | Implementation Notes | Post-MVP |
|---|---|---|---|---|
| Operational Excellence | 4 | 2 | 0 | 2 |
| Security | 5 | 3 | 1 | 1 |
| Reliability | 4 | 2 | 1 | 1 |
| Performance Efficiency | 3 | 3 | 0 | 0 |
| Cost Optimization | 2 | 2 | 0 | 0 |
| Sustainability | 2 | 2 | 0 | 0 |
| **Total** | **20** | **14** | **2** | **4** |

### Operational Excellence

| # | Finding | Risk | Status | Recommendation |
|---|---|---|---|---|
| OE-1 | Converter logs coverage percentage and resource counts to CloudWatch via `print()` | — | Already Addressed | No action needed |
| OE-2 | Static `reports:` with `ENABLE_SECURITY_SCAN=false` emits a non-fatal warning (design decision #9) | — | Already Addressed | No action needed |
| OE-3 | No CloudWatch alarm exists on `FailedBuilds` metric for `plan-dev` / `plan-prod` projects | Low | Post-MVP | Add a `aws_cloudwatch_metric_alarm` to core module for `FailedBuilds` on plan projects (module-wide gap, not specific to this feature) |
| OE-4 | No troubleshooting guidance for "coverage report missing from console" | Low | Post-MVP | Add a note to the module README covering the three causes: `ENABLE_SECURITY_SCAN=false`, Python exception, IAM misconfiguration |

### Security

| # | Finding | Risk | Status | Recommendation |
|---|---|---|---|---|
| SEC-1 | IAM scoped to `{project_name}-*` wildcard — matches AWS recommended project-scoped policy pattern | — | Already Addressed | Consistent with [AWS guidance](https://docs.aws.amazon.com/codebuild/latest/userguide/test-permissions.html) |
| SEC-2 | `tfplan.json` deleted immediately after scan; not leaked as an artifact | — | Already Addressed | No action needed |
| SEC-3 | `/tmp/checkov/` files are outside `$CODEBUILD_SRC_DIR` and never exported as pipeline artifacts | — | Already Addressed | No action needed |
| SEC-4 | Auto-created report groups use SSE-S3 encryption by default (not CMK) | Low | Post-MVP | Consistent with existing module-wide CMK deferral (see `main.tf` Checkov skips). Address via `aws_codebuild_report_group` with explicit KMS key post-MVP |
| SEC-5 | AWS Config rule `CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST` will flag auto-created groups as NON_COMPLIANT in CMK-enforcement environments | Medium | **Implementation Note** | When merging the MVP PR, add a note to the module README and the Post-MVP Enhancements table. Consumers enforcing this Config rule must add the `aws_codebuild_report_group` resource with KMS. See [Config rule reference](https://docs.aws.amazon.com/config/latest/developerguide/codebuild-report-group-encrypted-at-rest.html) |

### Reliability

| # | Finding | Risk | Status | Recommendation |
|---|---|---|---|---|
| REL-1 | `os.path.exists()` guard prevents `json.load()` crash on missing results file; `sys.exit(0)` allows `CHECKOV_EXIT` to re-raise cleanly | — | Already Addressed | No action needed |
| REL-2 | `json.load()` has no `try/except` for malformed JSON (e.g., truncated file from OOM kill) | Low | **Implementation Note** | Build fails safely via `set -e` and the Python traceback is visible in CloudWatch — acceptable for MVP. Post-MVP: wrap in `try/except json.JSONDecodeError` with a descriptive `print()` for improved diagnosability |
| REL-3 | CodeBuild report upload failure is non-fatal to the build (upload runs outside phase execution) | — | Already Addressed | Upload failures appear in CloudWatch logs; build status unaffected |
| REL-4 | No S3 export means reports are lost after CodeBuild's 30-day retention window | Low | Post-MVP | Add S3 export config to `aws_codebuild_report_group`; align retention with existing `artifact_retention_days` variable pattern |

### Performance Efficiency

| # | Finding | Risk | Status | Recommendation |
|---|---|---|---|---|
| PERF-1 | Single `checkov --output cli --output json` invocation — no duplicate scans (design decision #7) | — | Already Addressed | No action needed |
| PERF-2 | Converter is O(n) in check count; typical Terraform plans run in milliseconds | — | Already Addressed | No action needed |
| PERF-3 | `ET.indent()` requires Python 3.9+; default image `amazonlinux-x86_64-standard:5.0` ships Python 3.11 | — | Already Addressed | No compatibility concern |

### Cost Optimization

| # | Finding | Risk | Status | Recommendation |
|---|---|---|---|---|
| COST-1 | No per-report charge for CodeBuild report storage within the 30-day window | — | Already Addressed | No cost concern at expected pipeline run frequency |
| COST-2 | 30-day automatic expiry prevents unbounded storage growth | — | Already Addressed | No action needed; aligns with `log_retention_days` default |

### Sustainability

| # | Finding | Risk | Status | Recommendation |
|---|---|---|---|---|
| SUS-1 | No additional CodeBuild projects, build containers, or pipeline stages introduced | — | Already Addressed | Change is additive within an existing build execution |
| SUS-2 | Single Checkov invocation avoids redundant compute (design decision #7) | — | Already Addressed | No action needed |

### AWS Documentation References

| Topic | URL |
|---|---|
| Create code coverage reports | https://docs.aws.amazon.com/codebuild/latest/userguide/code-coverage-report.html |
| Test report permissions | https://docs.aws.amazon.com/codebuild/latest/userguide/test-permissions.html |
| Build specification reference (`reports:` syntax) | https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html |
| CodeBuild CloudWatch metrics | https://docs.aws.amazon.com/codebuild/latest/userguide/cloudwatch_metrics-codebuild.html |
| AWS Config rule: CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST | https://docs.aws.amazon.com/config/latest/developerguide/codebuild-report-group-encrypted-at-rest.html |
