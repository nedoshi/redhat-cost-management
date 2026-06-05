#!/usr/bin/env bash
# Validate Red Hat Cost Management — Azure side
# Requires: az login with access to the target subscription
# Set required env vars before running (see validation-from-bastion.md)
set -uo pipefail

# --- Required: set before running or pass as env vars ---
: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
: "${ARO_RG:?Set ARO_RG — resource group for export scope (cluster RG)}"
: "${CM_RG:?Set CM_RG — resource group where storage account lives}"
: "${CM_STORAGE:?Set CM_STORAGE — storage account name}"
: "${CM_EXPORT_NAME:?Set CM_EXPORT_NAME — cost export name in Azure}"
: "${AZ_CLIENT_ID:?Set AZ_CLIENT_ID — Red Hat integration service principal client ID}"

CONTAINER="${CM_CONTAINER:-costexport}"
EXPORT_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ARO_RG}"
STORAGE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${CM_RG}/providers/Microsoft.Storage/storageAccounts/${CM_STORAGE}"

PASS=0
FAIL=0
WARN=0

green()  { printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; ((PASS++)) || true; }
red()    { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; ((FAIL++)) || true; }
yellow() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; ((WARN++)) || true; }
info()   { printf '[INFO] %s\n' "$*"; }

section() { echo; echo "=== $* ==="; }

section "Prerequisites"
if ! command -v az >/dev/null 2>&1; then
  red "az CLI not found"
  exit 1
fi
green "az found: $(az version 2>/dev/null | head -1)"

if ! az account show >/dev/null 2>&1; then
  red "Not logged in — run: az login"
  exit 1
fi
green "Logged in as: $(az account show --query user.name -o tsv 2>/dev/null)"

ACTUAL_SUB=$(az account show --query id -o tsv 2>/dev/null)
if [[ "$ACTUAL_SUB" == "$SUBSCRIPTION_ID" ]]; then
  green "Subscription: $SUBSCRIPTION_ID"
else
  yellow "Active subscription ($ACTUAL_SUB) differs from SUBSCRIPTION_ID ($SUBSCRIPTION_ID)"
fi

section "Resource groups"
if az group show -n "$ARO_RG" >/dev/null 2>&1; then
  green "Export scope RG exists: $ARO_RG"
else
  red "Export scope RG not found: $ARO_RG"
fi

if az group show -n "$CM_RG" >/dev/null 2>&1; then
  green "Storage RG exists: $CM_RG"
else
  red "Storage RG not found: $CM_RG"
fi

section "Storage account"
if az storage account show -n "$CM_STORAGE" -g "$CM_RG" >/dev/null 2>&1; then
  green "Storage account exists: $CM_STORAGE in $CM_RG"

  PUBLIC_ACCESS=$(az storage account show -n "$CM_STORAGE" -g "$CM_RG" --query publicNetworkAccess -o tsv 2>/dev/null)
  info "publicNetworkAccess: ${PUBLIC_ACCESS:-unknown}"

  if [[ "$PUBLIC_ACCESS" == "Disabled" ]]; then
    yellow "Public network access disabled — Red Hat may not reach storage without private connectivity/IPs from Red Hat support"
  fi

  BYPASS=$(az storage account show -n "$CM_STORAGE" -g "$CM_RG" --query networkRuleSet.bypass -o tsv 2>/dev/null)
  if echo "$BYPASS" | grep -qi AzureServices; then
    green "Trusted Microsoft services bypass enabled (needed for cost export writes)"
  else
    yellow "Trusted Microsoft services may not be enabled — enable for Microsoft.CostManagementExports"
  fi
else
  red "Storage account not found: $CM_STORAGE in $CM_RG"
fi

section "Cost export"
if az costmanagement export show --name "$CM_EXPORT_NAME" --scope "$EXPORT_SCOPE" >/dev/null 2>&1; then
  green "Cost export exists: $CM_EXPORT_NAME at scope $EXPORT_SCOPE"
  az costmanagement export show --name "$CM_EXPORT_NAME" --scope "$EXPORT_SCOPE" \
    --query "{name:name, scheduleStatus:properties.schedule.status, recurrence:properties.schedule.recurrence}" -o table 2>/dev/null || true
else
  red "Cost export not found: $CM_EXPORT_NAME at scope $EXPORT_SCOPE"
  info "List exports: az costmanagement export list --scope \"$EXPORT_SCOPE\" -o table"
fi

section "Export blobs in storage"
if KEY=$(az storage account keys list -g "$CM_RG" -n "$CM_STORAGE" --query '[0].value' -o tsv 2>/dev/null); then
  BLOB_COUNT=$(az storage blob list --account-name "$CM_STORAGE" --container-name "$CONTAINER" \
    --account-key "$KEY" --query "length(@)" -o tsv 2>/dev/null || echo "0")
  if [[ "${BLOB_COUNT:-0}" -gt 0 ]]; then
    green "Found $BLOB_COUNT blob(s) in container '$CONTAINER'"
    az storage blob list --account-name "$CM_STORAGE" --container-name "$CONTAINER" \
      --account-key "$KEY" --query "[].{name:name, modified:properties.lastModified}" -o table 2>/dev/null | head -10
  else
    yellow "No blobs in container '$CONTAINER' yet — export may not have run (wait up to 24h or Run now in portal)"
  fi
else
  red "Could not read storage account keys"
fi

section "Service principal role assignments"
if az ad sp show --id "$AZ_CLIENT_ID" >/dev/null 2>&1; then
  green "Service principal exists: $AZ_CLIENT_ID"
else
  red "Service principal not found: $AZ_CLIENT_ID"
fi

ROLES=$(az role assignment list --assignee "$AZ_CLIENT_ID" --query "[].{role:roleDefinitionName, scope:scope}" -o tsv 2>/dev/null || true)
info "Role assignments for SP:"
echo "$ROLES" | while read -r line; do info "  $line"; done

if echo "$ROLES" | grep -q "Storage Blob Data Reader"; then
  if echo "$ROLES" | grep -q "$CM_STORAGE\|$CM_RG"; then
    green "Storage Blob Data Reader assigned (storage scope)"
  else
    yellow "Storage Blob Data Reader found but scope may not match storage account/RG"
  fi
else
  red "Missing Storage Blob Data Reader on storage account"
fi

if echo "$ROLES" | grep -q "Cost Management Reader"; then
  if echo "$ROLES" | grep -q "$ARO_RG\|$EXPORT_SCOPE"; then
    green "Cost Management Reader assigned (export scope)"
  else
    yellow "Cost Management Reader found but scope may not match export scope $ARO_RG"
  fi
else
  red "Missing Cost Management Reader on export scope ($ARO_RG)"
fi

section "Hybrid Cloud Console values (verify match)"
info "Cloud tab integration wizard should use:"
info "  Scope level:           Resource group"
info "  Resource group name:   $CM_RG  (storage RG — NOT necessarily $ARO_RG)"
info "  Storage account:       $CM_STORAGE"
info "  Cost export name:      $CM_EXPORT_NAME"
info "  Subscription ID:       $SUBSCRIPTION_ID"
info "  Client ID:             $AZ_CLIENT_ID"
info "If status is Unavailable: Edit integration (do not add duplicate) after fixing above"

section "Summary"
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo "---"
echo "Send this full output if sharing validation results."
if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: FAILED"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "Result: PASSED WITH WARNINGS"
  exit 0
else
  echo "Result: PASSED"
  exit 0
fi
