# Feature 8 — Examples and Validation

## Summary

Created three example root modules demonstrating how to consume the pipeline module: minimal (required variables only), complete (all variables with overrides), and opentofu (OpenTofu runtime). All examples pass `terraform init && terraform validate`.

## Files Changed

| File | Change |
|------|--------|
| `examples/minimal/main.tf` | Module invocation with required vars only |
| `examples/minimal/variables.tf` | 6 required variables passed through |
| `examples/complete/main.tf` | Module invocation with all vars populated |
| `examples/complete/variables.tf` | 8 variables (6 required + 2 for existing resources) |
| `examples/opentofu/main.tf` | Module invocation with `iac_runtime = "opentofu"` |
| `examples/opentofu/variables.tf` | 6 required variables passed through |

## Validation

All three examples:
- `terraform init -backend=false` — Success
- `terraform validate` — Success
- `terraform fmt -check -recursive` — Pass (no formatting issues)

## Decisions

1. **Examples use `source = "../../"`** — Relative path to module root, standard for in-repo examples.
2. **Complete example uses `create_state_bucket = false`** — Demonstrates the existing bucket flow with `state_bucket` variable and `codestar_connection_arn`.
3. **All examples set `provider "aws"` with `region = "ca-central-1"`** — Module does not configure providers (consumer responsibility), so examples must.
4. **Variables passed through, not hardcoded** — Examples declare their own variables and pass them to the module, following Terraform example conventions.
