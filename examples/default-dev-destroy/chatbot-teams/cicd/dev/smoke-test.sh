#!/usr/bin/env bash
# =============================================================================
# DEV Smoke Test Script
# =============================================================================
# This script runs AFTER terraform apply succeeds in the DEV environment
# (Stage 4 — Test DEV).
#
# Common uses:
#   - Verify deployed resources exist (e.g., aws s3api head-bucket)
#   - Hit health-check endpoints or API gateways
#   - Validate IAM roles/policies were created correctly
#   - Check CloudWatch alarms or log groups exist
#   - Run lightweight integration tests against DEV infrastructure
#
# Available environment variables:
#   PROJECT_NAME — pipeline project name
#   IAC_RUNTIME  — "terraform" or "opentofu"
#   IAC_VERSION  — version string or "latest"
#   TARGET_ENV   — "dev"
#   TARGET_ROLE  — ARN of the assumed cross-account role
#
# Notes:
#   - Working directory is the repo root (not iac_working_directory)
#   - AWS credentials are for the DEV target account (role already assumed)
#   - Keep tests fast — this gates the mandatory approval for PROD
#   - Exit non-zero to fail the pipeline and block PROD deployment
# =============================================================================
set -euo pipefail

echo "I am a test"
echo "Running ${TARGET_ENV} smoke tests for ${PROJECT_NAME}"

# Example: verify a resource exists in the DEV account
# aws s3api head-bucket --bucket "${PROJECT_NAME}-${TARGET_ENV}-assets" 2>/dev/null \
#   && echo "PASS: S3 bucket exists" \
#   || { echo "FAIL: S3 bucket not found"; exit 1; }
