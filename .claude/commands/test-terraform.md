---
name: test-terraform
description: Run all validation gates and commit. Only invoke when the user explicitly asks to run /test-terraform or says to test and commit a completed feature. Never invoke proactively.
---

# /test-terraform — Run All Gates and Commit

Execute the full testing workflow for the current feature. All gates must pass sequentially before committing.

## Prerequisites

Before running /test-terraform, ensure:
- You have completed the feature code
- The feature is marked `[~]` (in progress) in `progress.txt`
- You know which feature number you're completing (e.g., 2.1)

## Execution Steps

### Gate 1 & 2 — Validation

Run the automated test script that validates all modules, examples, and tests across the multi-variant repository structure.

**Command (validation only — default):**

```bash
bash tests/test-terraform.sh
```

**Command (validation + plan + apply for a specific variant):**

```bash
bash tests/test-terraform.sh --deploy <variant>
```

Where `<variant>` is one of: `default`, `default-dev-destroy`.

**Available flags:**

| Flag | Purpose |
|------|---------|
| `--target <name>` | Validate only a specific variant: `core`, `default`, `default-dev-destroy`. Default: `all` |
| `--deploy <name>` | Run plan + apply against `tests/<name>/` after validation. Implies `--target <name>` |
| `--skip-security` | Skip checkov and trivy scans |
| `--help` | Show usage |

The script automatically performs the following steps:

| Step | Tool | Purpose |
|------|------|---------|
| 1 | git-secrets | Scans for hardcoded secrets (AWS keys, passwords) |
| 2 | terraform fmt | Checks HCL formatting consistency (recursive) |
| 3 | terraform init + validate | Per-directory init and validation across all targeted modules, examples, and tests |
| 4 | tflint | Provider-aware linting per module (non-blocking) |
| 5 | checkov | Security scanning per module (non-blocking, skipped with `--skip-security`) |
| 6 | trivy | Security scanning per module (non-blocking, skipped with `--skip-security`) |
| 7 | terraform plan + apply | Only when `--deploy <name>` is passed; runs against `tests/<name>/` |

The script will:

- Auto-detect your OS (macOS, Ubuntu/Debian, RHEL/CentOS/Fedora)
- Install missing tools automatically using the appropriate package manager
- Iterate over all targeted directories (modules, examples, tests) for init/validate
- Stop on critical failures (Steps 1-3, 7)
- Continue with warnings for linting and security scan findings (Steps 4-6)
- Print a summary with pass/warn/fail counters

**Choosing the right command:**

- Feature is validation-only (no AWS deployment): `bash tests/test-terraform.sh`
- Feature adds/modifies a single variant: `bash tests/test-terraform.sh --target <variant>`
- Feature requires E2E deployment: `bash tests/test-terraform.sh --deploy <variant>`
- Quick iteration (skip slow security scans): `bash tests/test-terraform.sh --skip-security`

**Pass criteria:** Script exits with code 0 (all critical steps pass, warnings are acceptable)

**On failure:** STOP. Review the error output. Do not proceed to Gate 3.

**Note:** Checkov and Trivy security scans report findings as warnings but do not fail the pipeline. Review security findings and address them as needed, but they do not block validation. If security findings are false positives or accepted risks, it is acceptable to suppress specific rules:

- **Checkov**: Use inline comments in the terraform code `# checkov:skip=CKV_AWS_XX:Reason for suppression`
- **Trivy**: Use `.trivyignore` file or inline comments with `# trivy:ignore:AVD-AWS-XXXX`

Document suppression decisions in feature documentation or commit messages.

### Gate 3 — Commit

Only execute this gate if Gates 1–2 both passed.

1. **Read `progress.txt`** to identify the current in-progress feature (marked `[~]`)

2. **Update `progress.txt`:**
   - Change the feature status from `[~]` to `[x]`
   - Add completion date (format: `Completed YYYY-MM-DD`)

3. **Update `CHANGELOG.md`:**
   - Add entry for the completed feature
   - Format: `## [Feature X.Y] — YYYY-MM-DD` with brief summary

4. **Create feature documentation** at `docs/FEATURE_X.Y.md` (if it doesn't exist). Adapt sections to the feature type — not every section applies to every feature. Use this structure:

   ```markdown
   # Feature X.Y — [Title]

   ## Summary
   [1-2 sentences: what was built and why]

   ## Files Changed
   | File | Change |
   |------|--------|
   | `path/to/file` | What changed |

   ## Configuration
   [If new variables were added — variable name, type, default, description]

   ## Validation
   [Plan output summary: resources added/changed/destroyed]

   ## Decisions
   [Architecture or implementation choices and rationale. Deviations from PRD.]

   ## Verification
   [Commands to verify the feature works in a deployed environment]
   ```

   **Guidelines:**
   - Infrastructure features: emphasize Decisions, Verification (AWS CLI commands)
   - Config features: emphasize Configuration table, Files Changed
   - Module features: emphasize module inputs/outputs, Validation (plan summary)
   - Keep it factual and concise — not a tutorial, just a record

5. **Stage files individually** (never use `git add .` or `git add -A`):
   - Feature code files (modules/, examples/, tests/)
   - Updated progress.txt
   - Updated CHANGELOG.md
   - Feature documentation (docs/FEATURE_X.Y.md)
   - Any other files explicitly modified for this feature

6. **Generate commit message** based on feature context:
   - Format: `feat: X.Y — [Brief description from progress.txt]`

7. **Commit locally:**

   ```bash
   git commit -m "$(cat <<'EOF'
   feat: X.Y — [Description]

   [Optional: 1-2 sentence summary of what changed]
   EOF
   )"
   ```

8. **Do NOT push** — commits are local only per project rules

## Output Format

Report results after each gate:

```text
GATE 1 & 2 — Validation: PASS
  Script: bash tests/test-terraform.sh [flags used]
  Results: X passed, Y warnings, 0 failed

GATE 3 — Commit: PASS (committed as feat: X.Y — ...)

All gates passed. Feature X.Y is complete.
```

If deployment was included:

```text
GATE 1 & 2 — Validation, Plan & Apply: PASS
  Script: bash tests/test-terraform.sh --deploy <variant>
  Results: X passed, Y warnings, 0 failed
  Plan: 3 to add, 0 to change, 0 to destroy
  Apply: completed successfully

GATE 3 — Commit: PASS (committed as feat: X.Y — ...)

All gates passed. Feature X.Y is complete.
```

If any gate fails:

```text
GATE 1 & 2 — Validation: FAIL

Failed at: terraform validate (modules/default-dev-destroy)
Error: [error message]

Stopping. Please fix the error and run /test-terraform again.
```

## Important Rules

- **Sequential execution:** Never skip a gate or run gates in parallel
- **Stop on failure:** If any gate fails, stop immediately and report
- **No silent errors:** Always show the actual error output
- **Explicit staging:** Stage each file by name, never use wildcards
- **Local commits only:** Never push to remote
- **Feature documentation required:** Create docs/FEATURE_X.Y.md before committing
- **Plan before apply:** Never run `terraform apply` without reviewing `terraform plan` output first
- **Script is not executable:** Always invoke via `bash tests/test-terraform.sh`, never `./tests/test-terraform.sh`
