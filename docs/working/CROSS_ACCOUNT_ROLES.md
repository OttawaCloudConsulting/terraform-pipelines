# Cross-Account IAM Roles Documentation

## Overview

This document describes the IAM roles used for cross-account deployments in our AWS Organization. Two trust patterns are supported:

1. **Broker pattern** — `org-automation-broker-role` chains into deployment roles (for manual/script-based deployments)
2. **Direct pattern** — `CodeBuild-*-ServiceRole` assumes deployment roles directly (for terraform-pipelines module)

## Role Architecture

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

## Organization Details

- **Organization ID:** `o-sm2m8zg9c4`
- **Automation Account:** `389068787156` (aft-automation)
- **Target Accounts:**
  - `914089393341` (developer-account)
  - `264675080489` (network)

---

## 1. org-automation-broker-role

**Account:** aft-automation (389068787156)
**ARN:** `arn:aws:iam::389068787156:role/org/org-automation-broker-role`
**Path:** `/org/`
**Created:** 2026-02-12
**Tags:** `Deployment: Manual`

### Purpose

The broker role serves as the entry point for automated deployments. It's used by CI/CD pipelines (CodePipeline, CodeBuild) and automation scripts to assume deployment roles in target accounts.

### Trust Policy

**Who can assume this role:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "codebuild.amazonaws.com",
          "codepipeline.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    },
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::389068787156:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "o-sm2m8zg9c4"
        }
      }
    }
  ]
}
```

**Trusted principals:**
- AWS CodePipeline service
- AWS CodeBuild service
- IAM principals in aft-automation account (within organization)

### Permissions Policy

**What this role can do:**

#### 1. AssumeDeploymentRoles
```json
{
  "Sid": "AssumeDeploymentRoles",
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": [
    "arn:aws:iam::*:role/org/org-default-deployment-role",
    "arn:aws:iam::*:role/org/application-default-deployment-role"
  ],
  "Condition": {
    "StringEquals": {
      "aws:PrincipalOrgID": "o-sm2m8zg9c4"
    }
  }
}
```

**Purpose:** Allows assuming deployment roles in any account within the organization.

#### 2. CloudWatchLogsAccess
```json
{
  "Sid": "CloudWatchLogsAccess",
  "Effect": "Allow",
  "Action": [
    "logs:CreateLogGroup",
    "logs:CreateLogStream",
    "logs:PutLogEvents",
    "logs:DescribeLogGroups",
    "logs:DescribeLogStreams"
  ],
  "Resource": "arn:aws:logs:*:389068787156:log-group:/aws/automation/*"
}
```

**Purpose:** Write deployment logs and security information to CloudWatch in the automation account.

#### 3. ReadOrganizationInfo
```json
{
  "Sid": "ReadOrganizationInfo",
  "Effect": "Allow",
  "Action": [
    "organizations:DescribeAccount",
    "organizations:ListAccounts",
    "organizations:DescribeOrganization"
  ],
  "Resource": "*"
}
```

**Purpose:** Query organization structure to validate target accounts and gather metadata.

---

## 2. org-default-deployment-role

**Accounts:**
- developer-account (914089393341)
- network (264675080489)

**ARNs:**
- `arn:aws:iam::914089393341:role/org/org-default-deployment-role`
- `arn:aws:iam::264675080489:role/org/org-default-deployment-role`

**Path:** `/org/`

### Purpose

The default deployment role in target accounts. Used for organization-wide infrastructure deployments that don't require application-specific permissions.

### Trust Policy

**Updated 2026-02-12 — Added CodeBuild service role trust for terraform-pipelines module.**

The trust policy supports two assumption patterns:
1. **Broker pattern:** `org-automation-broker-role` assumes this role (role-chaining)
2. **Direct pattern:** `CodeBuild-*-ServiceRole` assumes this role directly (first-hop from CodeBuild)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TrustBrokerRole",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::389068787156:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "o-sm2m8zg9c4",
          "aws:PrincipalArn": "arn:aws:iam::389068787156:role/org/org-automation-broker-role"
        }
      }
    },
    {
      "Sid": "TrustCodeBuildServiceRoles",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::389068787156:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "o-sm2m8zg9c4"
        },
        "StringLike": {
          "aws:PrincipalArn": "arn:aws:iam::389068787156:role/CodeBuild-*-ServiceRole"
        }
      }
    }
  ]
}
```

**Key security controls:**
- Only the aft-automation account can assume this role
- Only the `org-automation-broker-role` or `CodeBuild-*-ServiceRole` roles specifically
- Must be within organization `o-sm2m8zg9c4`
- `StringLike` with wildcard allows any pipeline's CodeBuild role while scoping to the naming convention

### Permissions Policy

- **Attached policy:** `AdministratorAccess` (AWS managed)
- **Permissions boundary:** `Boundary-Boundary-Default` (see section 4)

### Permissions Boundary

See [Section 4: Boundary-Boundary-Default](#4-boundary-boundary-default) for the permissions boundary that constrains this role.

---

## 3. application-default-deployment-role

**Accounts:**
- developer-account (914089393341)
- network (264675080489)

**ARNs:**
- `arn:aws:iam::914089393341:role/org/application-default-deployment-role`
- `arn:aws:iam::264675080489:role/org/application-default-deployment-role`

**Path:** `/org/`

### Purpose

Application-specific deployment role in target accounts. Used for deploying application workloads with permissions scoped to application resources.

### Trust Policy

**Same dual-pattern trust as org-default-deployment-role:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TrustBrokerRole",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::389068787156:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "o-sm2m8zg9c4",
          "aws:PrincipalArn": "arn:aws:iam::389068787156:role/org/org-automation-broker-role"
        }
      }
    },
    {
      "Sid": "TrustCodeBuildServiceRoles",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::389068787156:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "o-sm2m8zg9c4"
        },
        "StringLike": {
          "aws:PrincipalArn": "arn:aws:iam::389068787156:role/CodeBuild-*-ServiceRole"
        }
      }
    }
  ]
}
```

### Permissions Policy

- **Attached policy:** `AdministratorAccess` (AWS managed)
- **Permissions boundary:** `Boundary-Boundary-Default` (see section 4)

---

## 4. Boundary-Boundary-Default

**Accounts:**
- developer-account: `arn:aws:iam::914089393341:policy/org/Boundary-Boundary-Default`
- network: `arn:aws:iam::264675080489:policy/org/Boundary-Boundary-Default`

**Path:** `/org/`
**Managed by:** AFT (Account Factory for Terraform)
**Tags:** `AFTCustomization: Baseline`, `Purpose: PermissionBoundary`, `Protection: PrivilegeEscalationPrevention`

### Purpose

Permissions boundary attached to deployment roles in target accounts. Defines the maximum permissions envelope — the role's effective permissions are the intersection of its identity policy (`AdministratorAccess`) and this boundary.

### Original Policy (v1)

The original boundary only had one Allow statement (`AllowOrganizationVisibility`) plus Deny statements. This meant the effective permissions were limited to `organizations:Describe*/List*` — deployment roles could not create any resources.

### Updated Policy (v2)

**Updated 2026-02-12 — Added `AllowAllServices` statement to enable deployments.**

Added a broad `Allow *:*` statement so the boundary acts as a deny-list (blocking specific dangerous actions) rather than an allow-list. The Deny statements continue to protect against privilege escalation.

**Change:** Added first statement:
```json
{
  "Sid": "AllowAllServices",
  "Effect": "Allow",
  "Action": "*",
  "Resource": "*"
}
```

**Full policy (account-specific versions in `docs/working/`):**
- DEV: `boundary-policy-dev.json`
- PROD: `boundary-policy-prod.json`

### Deny Statements (unchanged)

| Sid | What it protects |
|-----|-----------------|
| `DenyCreateProtectedRoles` | Prevents creating/modifying `org-*` roles |
| `DenyModifyProtectedRoles` | Prevents updating/deleting `org-*` roles |
| `DenyCreatePermissionBoundaryPolicies` | Prevents creating `Boundary-*` policies |
| `DenyModifyAnyBoundaryPolicy` | Prevents modifying `Boundary-*` policies |
| `DenyRemovingBoundaries` | Prevents removing boundaries from any role |
| `RequireBoundaryOnRoleCreation` | Forces `Boundary-Default` on new roles |
| `DenyBillingChanges` | Protects billing settings |
| `DenyMarketplaceSubscriptions` | Protects marketplace subscriptions |
| `DenyIdentityCenterChanges` | Protects SSO/Identity Center |
| `DenyCloudTrailChanges` | Protects CloudTrail configuration |
| `DenyConfigChanges` | Protects AWS Config configuration |
| `DenySecurityServiceChanges` | Protects GuardDuty, Security Hub, Access Analyzer |
| `ProtectInfrastructureLogs` | Protects AFT and org log groups |

### CLI Commands to Update

```bash
# DEV account — create new policy version
aws iam create-policy-version \
  --policy-arn "arn:aws:iam::914089393341:policy/org/Boundary-Boundary-Default" \
  --policy-document file://docs/working/boundary-policy-dev.json \
  --set-as-default \
  --profile developer-account

# PROD account — create new policy version
aws iam create-policy-version \
  --policy-arn "arn:aws:iam::264675080489:policy/org/Boundary-Boundary-Default" \
  --policy-document file://docs/working/boundary-policy-prod.json \
  --set-as-default \
  --profile network
```

**Note:** The boundary policy is managed by AFT (`ManagedBy: AFT` tag). These manual changes should be backported to the AFT baseline customization to prevent AFT from reverting them on the next account provisioning cycle.

---

## Role Chaining Flow

### Pattern 1: Broker-Based Deployment (Manual/Scripts)

1. **CodePipeline/CodeBuild** assumes `org-automation-broker-role` in aft-automation account
2. **Broker role** assumes `org-default-deployment-role` or `application-default-deployment-role` in target account
3. **Deployment role** performs infrastructure changes in target account
4. **Broker role** writes logs and audit information to automation account

### Pattern 2: Direct CodeBuild Deployment (terraform-pipelines module)

1. **CodePipeline** triggers CodeBuild with `CodeBuild-<project>-ServiceRole`
2. **CodeBuild service role** directly assumes `org-default-deployment-role` in target account (first-hop, no chaining)
3. **Deployment role** performs `terraform init`, `terraform apply` in target account
4. **CodeBuild service role** writes logs to CloudWatch in automation account

### AWS CLI Example (Broker Pattern)

```bash
# Step 1: Assume broker role (typically done by CodeBuild/CodePipeline automatically)
aws sts assume-role \
  --role-arn arn:aws:iam::389068787156:role/org/org-automation-broker-role \
  --role-session-name deployment-session

# Step 2: Using broker role credentials, assume deployment role in target account
aws sts assume-role \
  --role-arn arn:aws:iam::914089393341:role/org/org-default-deployment-role \
  --role-session-name target-deployment

# Step 3: Use target account credentials for deployment
terraform apply
```

### Terraform Example (Direct Pattern — terraform-pipelines module)

```hcl
# CodeBuild service role assumes deployment role directly
# This happens inside the buildspec via aws sts assume-role
# The CodeBuild project runs as CodeBuild-<project>-ServiceRole
# which has sts:AssumeRole permission for the deployment role ARN
```

---

## Security Considerations

### Least Privilege
- Broker role has minimal permissions (only assume role + logging)
- CodeBuild service roles are scoped to exactly two deployment role ARNs (dev + prod)
- Deployment roles have `AdministratorAccess` constrained by permissions boundary
- Organization ID condition prevents cross-organization attacks
- Permissions boundary prevents privilege escalation to org-managed roles

### Audit Trail
- All role assumptions logged to CloudTrail
- Deployment logs written to `/aws/automation/*` log groups
- Session names should include deployment context

### Role Chaining Limits
- Direct pattern (CodeBuild → deployment role) is first-hop, not chaining
- Broker pattern (broker → deployment role) is one hop of chaining
- Maximum session duration: 1 hour (can be increased to 12 hours)

### Trust Policy Specificity
- `aws:PrincipalArn` condition prevents other roles in automation account from assuming deployment roles
- `StringLike` with `CodeBuild-*-ServiceRole` pattern scopes to pipeline-created roles only
- More secure than just trusting the account root

### Permissions Boundary Protection
- Deployment roles cannot modify `org-*` roles or `Boundary-*` policies
- New roles created by deployments must have `Boundary-Default` attached
- CloudTrail, Config, GuardDuty, and Security Hub are protected from modification
- AFT infrastructure logs are protected from deletion

---

## Troubleshooting

### "Access Denied" when assuming deployment role

**Check:**
1. CodeBuild service role has `sts:AssumeRole` permission for target role ARN
2. Target role trusts the CodeBuild service role pattern (`CodeBuild-*-ServiceRole`)
3. Both accounts are in organization `o-sm2m8zg9c4`
4. Session hasn't exceeded maximum duration
5. CodeBuild role name follows the `CodeBuild-<project>-ServiceRole` naming convention

### "no permissions boundary allows the action"

**Check:**
1. The `Boundary-Boundary-Default` policy has the `AllowAllServices` statement
2. The action is not in one of the Deny statements
3. Run: `aws iam get-policy-version --policy-arn <boundary-arn> --version-id <version> --profile <profile>`

### "Role does not exist"

**Verify:**
```bash
# Check if broker role exists
aws iam get-role --role-name org-automation-broker-role --profile aft-automation

# Check if deployment role exists in target
aws iam get-role --role-name org-default-deployment-role --profile developer-account
```

### Trust relationship issues

**Validate trust policy:**
```bash
aws iam get-role \
  --role-name org-default-deployment-role \
  --profile developer-account \
  --query 'Role.AssumeRolePolicyDocument' \
  --output json
```

---

## Maintenance

### Adding New Target Accounts

When adding a new account to the organization:

1. Create `org-default-deployment-role` in the new account
2. Set trust policy with both statements (broker role + CodeBuild service roles)
3. Attach `AdministratorAccess` (or scoped policy)
4. Attach `Boundary-Boundary-Default` as permissions boundary (with `AllowAllServices`)
5. Test role assumption from automation account

### Updating Trust Policy on Deployment Roles

To update the trust policy (e.g., after adding a new trust pattern):

```bash
# Update trust policy in DEV account
aws iam update-assume-role-policy \
  --role-name org-default-deployment-role \
  --policy-document file://trust-policy.json \
  --profile developer-account

# Update trust policy in PROD account
aws iam update-assume-role-policy \
  --role-name org-default-deployment-role \
  --policy-document file://trust-policy.json \
  --profile network
```

### Updating Permissions Boundary

To update the boundary policy (creates a new version):

```bash
# DEV account
aws iam create-policy-version \
  --policy-arn "arn:aws:iam::914089393341:policy/org/Boundary-Boundary-Default" \
  --policy-document file://boundary-policy-dev.json \
  --set-as-default \
  --profile developer-account

# PROD account
aws iam create-policy-version \
  --policy-arn "arn:aws:iam::264675080489:policy/org/Boundary-Boundary-Default" \
  --policy-document file://boundary-policy-prod.json \
  --set-as-default \
  --profile network
```

**Important:** Backport changes to AFT baseline customization to prevent reversion.

### Updating Permissions

To update broker role permissions:

```bash
aws iam put-role-policy \
  --role-name org-automation-broker-role \
  --policy-name org-automation-broker-permissions \
  --policy-document file://updated-policy.json \
  --profile aft-automation
```

To update deployment role permissions in target accounts:

```bash
aws iam put-role-policy \
  --role-name org-default-deployment-role \
  --policy-name <policy-name> \
  --policy-document file://updated-policy.json \
  --profile developer-account
```

---

## Change Log

| Date | Change | Reason |
|------|--------|--------|
| 2026-02-12 | Initial creation | Document existing cross-account role architecture |
| 2026-02-12 | Added `TrustCodeBuildServiceRoles` statement to deployment roles | terraform-pipelines module uses direct CodeBuild → deployment role assumption (first-hop), not broker role chaining |
| 2026-02-12 | Added `AllowAllServices` to `Boundary-Boundary-Default` (v1 → v2) | Original boundary only allowed `organizations:*` reads — deployment roles could not create any resources |

---

## References

- [AWS IAM Role Chaining](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_terms-and-concepts.html)
- [Control Tower Account Factory for Terraform (AFT)](https://docs.aws.amazon.com/controltower/latest/userguide/aft-overview.html)
- [SCP and Permission Boundaries](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
- [IAM Permissions Boundaries](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)

---

**Document Version:** 1.2
**Last Updated:** 2026-02-12
**Owner:** Cloud Platform Team
