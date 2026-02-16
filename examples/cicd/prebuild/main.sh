#!/usr/bin/env bash
# =============================================================================
# Pre-Build Script
# =============================================================================
# This script runs BEFORE terraform plan/apply in Stage 2 (Pre-Build).
# It executes in the repo root directory with no cross-account role assumed.
#
# Common uses:
#   - Install project-specific CLI tools (e.g., tflint, tfsec, custom linters)
#   - Run code generation or template rendering
#   - Pull shared modules or configs from private registries
#   - Validate project structure or naming conventions
#   - Run pre-flight checks (e.g., verify external dependencies are reachable)
#
# Available environment variables:
#   PROJECT_NAME  — pipeline project name
#   IAC_RUNTIME   — "terraform" or "opentofu"
#   IAC_VERSION   — version string or "latest"
#
# Notes:
#   - Working directory is the repo root (not iac_working_directory)
#   - No AWS cross-account credentials are available at this stage
#   - Install tools to /usr/local/bin/ for availability in later stages
#   - Exit non-zero to fail the pipeline
# =============================================================================
set -euo pipefail

echo "I am a test"
echo "Pre-build script for ${PROJECT_NAME} using ${IAC_RUNTIME} ${IAC_VERSION}"
