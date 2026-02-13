# Multi-Variant Pipeline Restructure

## Summary

Restructured the monolithic root-level Terraform module into a shared core + variant wrapper architecture. The core module provides IAM, S3, SNS, CodeBuild, and CloudWatch resources, while variant wrappers compose it and own CodePipeline definitions. Two variants are implemented: Default (9-stage) and Default-DevDestroy (10-11 stage with ephemeral DEV teardown).

## Features Implemented

| Feature | Description |
|---------|-------------|
| 1 | Core module extraction — moved root .tf files into `modules/core/` |
| 2 | Default variant wrapper — 9-stage CodePipeline V2 with moved blocks for migration |
| 3 | Default-DevDestroy variant — 10-11 stage pipeline with destroy stage |
| 4 | Destroy buildspec — `terraform destroy` against DEV environment |
| 5 | Per-variant examples (5 total) |
| 6 | Per-variant tests (2 total) |
| 7 | Documentation restructure |

## Files Changed

| Path | Change |
|------|--------|
| `modules/core/*.tf` | New — extracted from root module |
| `modules/core/buildspecs/*.yml` | Moved from `buildspecs/` |
| `modules/default/main.tf` | New — 9-stage pipeline + 28 moved blocks |
| `modules/default/variables.tf` | New — 19 uniform variables |
| `modules/default/outputs.tf` | New — 11 uniform outputs |
| `modules/default/versions.tf` | New — provider requirements |
| `modules/default-dev-destroy/main.tf` | New — 10-11 stage pipeline + destroy resources |
| `modules/default-dev-destroy/variables.tf` | New — 19 base + `enable_destroy_approval` |
| `modules/default-dev-destroy/outputs.tf` | New — 11 outputs (merges destroy into codebuild map) |
| `modules/default-dev-destroy/versions.tf` | New — provider requirements |
| `modules/default-dev-destroy/buildspecs/destroy.yml` | New — DEV destroy buildspec |
| `examples/default/minimal/` | New — required variables only |
| `examples/default/complete/` | New — all variables with production overrides |
| `examples/default/opentofu/` | New — OpenTofu runtime example |
| `examples/default/single-account/` | New — same-account deployment |
| `examples/default-dev-destroy/minimal/` | New — minimal dev-destroy example |
| `tests/default/main.tf` | New — default variant validation |
| `tests/default-dev-destroy/main.tf` | New — dev-destroy variant validation |
| `docs/default/README.md` | New — default variant documentation |
| `docs/default/single-account.md` | New — single-account usage guide |
| `docs/default-dev-destroy/README.md` | New — dev-destroy variant documentation |
| `docs/shared/` | Moved — diagrams and MVP statement |
| Root `.tf` files | Deleted — replaced by modules |
| Old `examples/` | Deleted — replaced by per-variant examples |

## Architecture

```
modules/core/          ← Shared infrastructure (IAM, S3, SNS, CodeBuild, CloudWatch)
modules/default/       ← Default variant (9-stage pipeline, migration-safe)
modules/default-dev-destroy/  ← DevDestroy variant (10-11 stages, ephemeral DEV)
```

**IAM extensibility pattern:** Core accepts `additional_codebuild_project_arns` and `additional_log_group_arns` so variants can register their own resources with core IAM policies.

## Decisions

- **Uniform variable interface**: All variants expose the same 19 base variables. Variant-specific variables are additive (e.g., `enable_destroy_approval`).
- **Moved blocks in Default variant**: 28 `moved` blocks enable zero-downtime migration from the monolithic root module.
- **Destroy hardcoded to DEV**: The destroy buildspec targets DEV only (not parameterized by `TARGET_ENV`) since destroy is only ever against DEV.
- **`enable_destroy_approval` defaults to `true`**: Safe by default — manual approval required before DEV destruction.
- **Single-account variant removed**: Single-account deployment is supported as a configuration of the Default variant (set `dev_account_id == prod_account_id`), not as a separate variant.

## Validation

- `terraform validate`: All 3 modules, 5 examples, 2 tests pass
- `terraform fmt -check -recursive`: Pass
- `git-secrets --scan`: Pass
- `checkov`: 68 passed, 0 failed, 47 skipped
- `trivy`: SNS KMS warning only (accepted risk)
- `tflint`: 3 unused variable warnings in core (intentional pass-through variables)
