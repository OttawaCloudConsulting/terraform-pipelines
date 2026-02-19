#!/bin/bash
set -euo pipefail

# =============================================================================
# test-terraform.sh — Multi-variant Terraform validation and deployment script
#
# Validates modules, examples, and tests across the multi-variant repository
# structure. Supports selective targeting and plan/apply for E2E testing.
#
# Usage:
#   bash tests/test-terraform.sh                    # validate all modules, examples, tests
#   bash tests/test-terraform.sh --target default   # validate only the default variant
#   bash tests/test-terraform.sh --target core      # validate only the core module
#   bash tests/test-terraform.sh --deploy default   # validate + plan + apply tests/default/
#   bash tests/test-terraform.sh --deploy default-dev-destroy
#   bash tests/test-terraform.sh --skip-security    # skip checkov and trivy scans
#   bash tests/test-terraform.sh --help
#
# Targets:  all (default), core, default, default-dev-destroy
# Flags:    --target <name>, --deploy <name>, --skip-security, --help
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# AWS Profile for deploying to the Automation Account.
# Only set if not already defined by the caller.
export AWS_PROFILE="${AWS_PROFILE:?AWS_PROFILE must be set to the Automation Account CLI profile}"

# Defaults
TARGET="all"
DEPLOY=""
SKIP_SECURITY=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# ---- Output helpers ---------------------------------------------------------

print_step() {
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}Step $1: $2${NC}"
    echo -e "${GREEN}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}  pass  $1${NC}"
    PASS_COUNT=$((PASS_COUNT + 1))
}

print_warning() {
    echo -e "${YELLOW}  warn  $1${NC}"
    WARN_COUNT=$((WARN_COUNT + 1))
}

print_error() {
    echo -e "${RED}  FAIL  $1${NC}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

print_info() {
    echo -e "  ....  $1"
}

# ---- Utilities --------------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian) echo "debian" ;;
            rhel|centos|fedora) echo "redhat" ;;
            *) echo "linux" ;;
        esac
    else
        echo "unknown"
    fi
}

install_tool() {
    local tool=$1
    local install_method=$2
    local os
    os=$(detect_os)

    print_info "$tool not found. Attempting install..."

    case $install_method in
        brew)
            case $os in
                macos)
                    if command_exists brew; then
                        brew install "$tool"
                    else
                        print_warning "Homebrew not installed. Please install $tool manually."
                        return 1
                    fi
                    ;;
                debian)
                    if command_exists apt-get; then
                        sudo apt-get update && sudo apt-get install -y "$tool"
                    else
                        print_warning "apt-get not available. Please install $tool manually."
                        return 1
                    fi
                    ;;
                redhat)
                    if command_exists dnf; then
                        sudo dnf install -y "$tool"
                    elif command_exists yum; then
                        sudo yum install -y "$tool"
                    else
                        print_warning "dnf/yum not available. Please install $tool manually."
                        return 1
                    fi
                    ;;
                *)
                    print_warning "Unsupported OS. Please install $tool manually."
                    return 1
                    ;;
            esac
            ;;
        pip)
            if command_exists pip3; then
                pip3 install --user "$tool"
            elif command_exists pip; then
                pip install --user "$tool"
            else
                print_warning "pip not installed. Please install $tool manually."
                return 1
            fi
            ;;
        *)
            print_warning "Please install $tool manually."
            return 1
            ;;
    esac
}

# ---- Directory discovery ----------------------------------------------------

# Build arrays of directories to validate based on --target.
# Each array element is an absolute path to a directory containing .tf files.
build_target_lists() {
    MODULES=()
    EXAMPLES=()
    TESTS=()

    case "$TARGET" in
        all)
            MODULES=(
                "$REPO_ROOT/modules/core"
                "$REPO_ROOT/modules/default"
                "$REPO_ROOT/modules/default-dev-destroy"
            )
            # Discover all example and test directories containing .tf files
            while IFS= read -r dir; do
                EXAMPLES+=("$dir")
            done < <(find "$REPO_ROOT/examples" -name '*.tf' -print0 | xargs -0 -n1 dirname | sort -u)
            while IFS= read -r dir; do
                TESTS+=("$dir")
            done < <(find "$REPO_ROOT/tests" -name '*.tf' -not -path '*/test-terraform.sh' -print0 | xargs -0 -n1 dirname | sort -u)
            ;;
        core)
            MODULES=("$REPO_ROOT/modules/core")
            ;;
        default)
            MODULES=(
                "$REPO_ROOT/modules/core"
                "$REPO_ROOT/modules/default"
            )
            while IFS= read -r dir; do
                EXAMPLES+=("$dir")
            done < <(find "$REPO_ROOT/examples/default" -name '*.tf' -print0 2>/dev/null | xargs -0 -n1 dirname | sort -u)
            if [[ -d "$REPO_ROOT/tests/default" ]]; then
                TESTS=("$REPO_ROOT/tests/default")
            fi
            ;;
        default-dev-destroy)
            MODULES=(
                "$REPO_ROOT/modules/core"
                "$REPO_ROOT/modules/default-dev-destroy"
            )
            while IFS= read -r dir; do
                EXAMPLES+=("$dir")
            done < <(find "$REPO_ROOT/examples/default-dev-destroy" -name '*.tf' -print0 2>/dev/null | xargs -0 -n1 dirname | sort -u)
            if [[ -d "$REPO_ROOT/tests/default-dev-destroy" ]]; then
                TESTS=("$REPO_ROOT/tests/default-dev-destroy")
            fi
            ;;
        *)
            echo -e "${RED}Unknown target: $TARGET${NC}"
            echo "Valid targets: all, core, default, default-dev-destroy"
            exit 1
            ;;
    esac

    ALL_DIRS=("${MODULES[@]}" "${EXAMPLES[@]}" "${TESTS[@]}")
}

# Short label for a directory (relative to repo root)
label() {
    echo "${1#"$REPO_ROOT/"}"
}

# ---- Argument parsing -------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage: bash tests/test-terraform.sh [OPTIONS]

Options:
  --target <name>   Validate a specific variant (core, default, default-dev-destroy)
                    Default: all
  --deploy <name>   Run plan + apply against tests/<name>/ after validation
                    Requires AWS credentials for the Automation Account
  --skip-security   Skip checkov and trivy scans
  --help            Show this help message

Examples:
  bash tests/test-terraform.sh
  bash tests/test-terraform.sh --target default
  bash tests/test-terraform.sh --deploy default
  bash tests/test-terraform.sh --target default-dev-destroy --skip-security
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            TARGET="$2"
            shift 2
            ;;
        --deploy)
            DEPLOY="$2"
            shift 2
            ;;
        --skip-security)
            SKIP_SECURITY=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# If --deploy is given without --target, scope target to match
if [[ -n "$DEPLOY" && "$TARGET" == "all" ]]; then
    TARGET="$DEPLOY"
fi

build_target_lists

echo -e "${GREEN}Target:${NC}  $TARGET"
echo -e "${GREEN}Deploy:${NC}  ${DEPLOY:-none}"
echo -e "${GREEN}Modules:${NC} ${#MODULES[@]}  Examples: ${#EXAMPLES[@]}  Tests: ${#TESTS[@]}"

# =============================================================================
# Step 1: git-secrets
# =============================================================================
print_step 1 "git-secrets — scanning for hardcoded secrets"
if ! command_exists git-secrets; then
    install_tool "git-secrets" "brew" || true
fi

if command_exists git-secrets; then
    if git -C "$REPO_ROOT" secrets --scan; then
        print_success "git-secrets: no secrets found"
    else
        print_error "git-secrets: potential secrets detected"
        exit 1
    fi
else
    print_warning "git-secrets: not available, skipped"
fi

# =============================================================================
# Step 2: terraform fmt
# =============================================================================
print_step 2 "terraform fmt — checking HCL formatting"
if ! command_exists terraform; then
    install_tool "terraform" "brew" || true
fi

if ! command_exists terraform; then
    print_error "terraform: not available, cannot proceed"
    exit 1
fi

if terraform fmt -check -recursive "$REPO_ROOT"; then
    print_success "terraform fmt: formatting correct"
else
    print_error "terraform fmt: formatting issues found (run 'terraform fmt -recursive' to fix)"
    exit 2
fi

# =============================================================================
# Step 3: terraform init + validate (per directory)
# =============================================================================
print_step 3 "terraform init + validate — all target directories"

for dir in "${ALL_DIRS[@]}"; do
    print_info "$(label "$dir")"
    if terraform -chdir="$dir" init -backend=false -input=false >/dev/null 2>&1; then
        if terraform -chdir="$dir" validate >/dev/null 2>&1; then
            print_success "$(label "$dir"): valid"
        else
            print_error "$(label "$dir"): validate failed"
            terraform -chdir="$dir" validate
            exit 3
        fi
    else
        print_error "$(label "$dir"): init failed"
        terraform -chdir="$dir" init -backend=false -input=false
        exit 3
    fi
done

# =============================================================================
# Step 4: tflint
# =============================================================================
print_step 4 "tflint — provider-aware linting"
if ! command_exists tflint; then
    install_tool "tflint" "brew" || true
fi

if command_exists tflint; then
    tflint --init --config="$REPO_ROOT/.tflint.hcl" 2>/dev/null || tflint --init 2>/dev/null || true
    TFLINT_FAILED=false
    for dir in "${MODULES[@]}"; do
        print_info "$(label "$dir")"
        if tflint --chdir="$dir" 2>&1; then
            print_success "$(label "$dir"): tflint clean"
        else
            print_warning "$(label "$dir"): tflint findings (non-blocking)"
            TFLINT_FAILED=true
        fi
    done
    if [[ "$TFLINT_FAILED" == "false" ]]; then
        print_success "tflint: all modules clean"
    fi
else
    print_warning "tflint: not available, skipped"
fi

# =============================================================================
# Step 5: checkov (advisory)
# =============================================================================
if [[ "$SKIP_SECURITY" == "false" ]]; then
    print_step 5 "checkov — security scanning"
    if ! command_exists checkov; then
        install_tool "checkov" "pip" || true
    fi

    if command_exists checkov; then
        for dir in "${MODULES[@]}"; do
            print_info "$(label "$dir")"
            if checkov -d "$dir" --framework terraform --quiet --compact 2>&1; then
                print_success "$(label "$dir"): checkov passed"
            else
                print_warning "$(label "$dir"): checkov findings (non-blocking)"
            fi
        done
    else
        print_warning "checkov: not available, skipped"
    fi

    # =========================================================================
    # Step 6: trivy (advisory)
    # =========================================================================
    print_step 6 "trivy — security scanning"
    if ! command_exists trivy; then
        install_tool "trivy" "brew" || true
    fi

    if command_exists trivy; then
        for dir in "${MODULES[@]}"; do
            print_info "$(label "$dir")"
            if trivy fs "$dir" --scanners misconfig --severity HIGH,CRITICAL 2>&1; then
                print_success "$(label "$dir"): trivy passed"
            else
                print_warning "$(label "$dir"): trivy findings (non-blocking)"
            fi
        done
    else
        print_warning "trivy: not available, skipped"
    fi
else
    print_step 5 "checkov — skipped (--skip-security)"
    print_step 6 "trivy — skipped (--skip-security)"
fi

# =============================================================================
# Step 7: terraform plan + apply (only with --deploy)
# =============================================================================
if [[ -n "$DEPLOY" ]]; then
    DEPLOY_DIR="$REPO_ROOT/tests/$DEPLOY"

    if [[ ! -d "$DEPLOY_DIR" ]]; then
        print_error "Deploy directory not found: tests/$DEPLOY/"
        echo "Available test directories:"
        find "$REPO_ROOT/tests" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;
        exit 4
    fi

    print_step 7a "terraform plan — tests/$DEPLOY/"
    terraform -chdir="$DEPLOY_DIR" init -input=false
    terraform -chdir="$DEPLOY_DIR" plan -out=tfplan
    print_success "terraform plan: tests/$DEPLOY/ plan generated"

    print_step 7b "terraform apply — tests/$DEPLOY/"
    terraform -chdir="$DEPLOY_DIR" apply -input=false tfplan
    rm -f "$DEPLOY_DIR/tfplan"
    print_success "terraform apply: tests/$DEPLOY/ deployed"
else
    print_step 7 "terraform plan + apply — skipped (use --deploy <name> to enable)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Results: ${PASS_COUNT} passed, ${WARN_COUNT} warnings, ${FAIL_COUNT} failed${NC}"
echo -e "${GREEN}========================================${NC}"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
