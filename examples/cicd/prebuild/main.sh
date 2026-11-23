#!/usr/bin/env bash
# =============================================================================
# Pre-Build Script
# =============================================================================
# This script runs BEFORE terraform plan/apply in Stage 2 (Pre-Build).
# It executes in the repo root directory with no cross-account role assumed.
#
# Common uses (checks only, pass or fail):
#   - Validate project structure or naming conventions
#   - Run linters or static analysis (e.g., tflint, tfsec) as a gate
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
#   - Pre-Build is its own CodeBuild project with no output artifact. Tools it
#     installs and files it creates or changes do NOT reach the Plan, Deploy or
#     Test stages, which start from the original source. Use this stage for
#     checks only, not for code generation or setup that later stages need.
#   - Exit non-zero to fail the pipeline
# =============================================================================
set -euo pipefail

echo "I am a test"
echo "Pre-build script for ${PROJECT_NAME} using ${IAC_RUNTIME} ${IAC_VERSION}"
