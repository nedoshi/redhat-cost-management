#!/usr/bin/env bash
# Validate Red Hat Cost Management — Azure side
# Requires: az login with access to the target subscription
# Set required env vars before running (see validation-from-bastion.md)
set -uo pipefail

# --- Required: set before running or pass as env vars ---
: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID — subscription for export scope (ARO cluster)}"
: "${ARO_RG:?Set ARO_RG — resource group for export scope (cluster RG)}"
: "${CM_RG:?Set CM_RG — resource group where storage account lives}"
: "${CM_STORAGE:?Set CM_STORAGE — storage account name}"
: "${CM_EXPORT_NAME:?Set CM_EXPORT_NAME — cost export name in Azure}"
: "${AZ_CLIENT_ID:?Set AZ_CLIENT_ID — Red Hat integration service principal client ID}"

# Storage subscription — defaults to SUBSCRIPTION_ID when storage is in the same subscription
CM_SUBSCRIPTION_ID="${CM_SUBSCRIPTION_ID:-$SUBSCRIPTION_ID}"

CONTAINER="${CM_CONTAINER:-costexport}"
EXPORT_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ARO_RG}"
STORAGE_ID="/subscriptions/${CM_SUBSCRIPTION_ID}/resourceGroups/${CM_RG}/providers/Microsoft.Storage/storageAccounts/${CM_STORAGE}"

PASS=0
FAIL=0
WARN=0
RECOMMENDATIONS=()

green()  { printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; ((PASS++)) || true; }
red()    { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; ((FAIL++)) || true; }
yellow() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; ((WARN++)) || true; }
info()   { printf '[INFO] %s\n' "$*"; }
recommend() { RECOMMENDATIONS+=("$*"); }

section() { echo; echo "=== $* ==="; }

section "Prerequisites"
if ! command -v az >/dev/null 2>&1; then
  red "az CLI not found"
  recommend "Install Azure CLI: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
  section "Recommendations"
  for i in "${!RECOMMENDATIONS[@]}"; do echo "$((i + 1)). ${RECOMMENDATIONS[$i]}"; done
  exit 1
fi
green "az found: $(az version 2>/dev/null | head -1)"

if ! az account show >/dev/null 2>&1; then
  red "Not logged in — run: az login"
  recommend "Run: az login"
  recommend "Then set the export-scope subscription: az account set --subscription \"$SUBSCRIPTION_ID\""
  section "Recommendations"
  for i in "${!RECOMMENDATIONS[@]}"; do echo "$((i + 1)). ${RECOMMENDATIONS[$i]}"; done
  exit 1
fi
green "Logged in as: $(az account show --query user.name -o tsv 2>/dev/null)"

ACTUAL_SUB=$(az account show --query id -o tsv 2>/dev/null)
if [[ "$ACTUAL_SUB" == "$SUBSCRIPTION_ID" ]]; then
  green "Active subscription matches SUBSCRIPTION_ID (export scope): $SUBSCRIPTION_ID"
else
  yellow "Active subscription ($ACTUAL_SUB) differs from SUBSCRIPTION_ID ($SUBSCRIPTION_ID) — script uses --subscription flags"
  recommend "Confirm SUBSCRIPTION_ID is the export-scope subscription (where \$ARO_RG lives), not the storage subscription."
fi

if [[ "$CM_SUBSCRIPTION_ID" == "$SUBSCRIPTION_ID" ]]; then
  info "Storage subscription: same as export scope ($SUBSCRIPTION_ID)"
else
  info "Storage subscription: $CM_SUBSCRIPTION_ID (cross-subscription setup)"
fi

section "Resource groups"
if az group show -n "$ARO_RG" --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
  green "Export scope RG exists: $ARO_RG (subscription $SUBSCRIPTION_ID)"
else
  red "Export scope RG not found: $ARO_RG in subscription $SUBSCRIPTION_ID"
  recommend "Verify ARO_RG matches the cluster resource group: az aro list --subscription \"$SUBSCRIPTION_ID\" -o table"
  recommend "If wrong subscription, fix SUBSCRIPTION_ID or run: az account set --subscription \"<correct-sub-id>\""
fi

if az group show -n "$CM_RG" --subscription "$CM_SUBSCRIPTION_ID" >/dev/null 2>&1; then
  green "Storage RG exists: $CM_RG (subscription $CM_SUBSCRIPTION_ID)"
else
  red "Storage RG not found: $CM_RG in subscription $CM_SUBSCRIPTION_ID"
  recommend "Create the storage RG or fix CM_RG / CM_SUBSCRIPTION_ID."
  recommend "Create RG: az group create -n \"$CM_RG\" -l eastus --subscription \"$CM_SUBSCRIPTION_ID\""
fi

section "Storage account"
if az storage account show -n "$CM_STORAGE" -g "$CM_RG" --subscription "$CM_SUBSCRIPTION_ID" >/dev/null 2>&1; then
  green "Storage account exists: $CM_STORAGE in $CM_RG (subscription $CM_SUBSCRIPTION_ID)"

  PUBLIC_ACCESS=$(az storage account show -n "$CM_STORAGE" -g "$CM_RG" --subscription "$CM_SUBSCRIPTION_ID" --query publicNetworkAccess -o tsv 2>/dev/null)
  info "publicNetworkAccess: ${PUBLIC_ACCESS:-unknown}"

  if [[ "$PUBLIC_ACCESS" == "Disabled" ]]; then
    yellow "Public network access disabled — Red Hat may not reach storage without private connectivity/IPs from Red Hat support"
    recommend "Enable public network access on the storage account, or open a Red Hat support case for Cost Management egress IPs."
    recommend "Portal: Storage account → Networking → Public network access → Enabled from selected networks (with trusted MS services)."
  fi

  BYPASS=$(az storage account show -n "$CM_STORAGE" -g "$CM_RG" --subscription "$CM_SUBSCRIPTION_ID" --query networkRuleSet.bypass -o tsv 2>/dev/null)
  if echo "$BYPASS" | grep -qi AzureServices; then
    green "Trusted Microsoft services bypass enabled (needed for cost export writes)"
  else
    yellow "Trusted Microsoft services may not be enabled — enable for Microsoft.CostManagementExports"
    recommend "Portal: Storage account → Networking → enable \"Allow trusted Microsoft services to access this storage account\"."
    recommend "This is required for Azure Cost Management export writes (Microsoft.CostManagementExports)."
  fi
else
  red "Storage account not found: $CM_STORAGE in $CM_RG (subscription $CM_SUBSCRIPTION_ID)"
  recommend "Create storage account and container — see docs/cost-management/aro_hybrid_cost_management_guide.md Step 1."
  recommend "Quick create: az storage account create -n \"$CM_STORAGE\" -g \"$CM_RG\" --subscription \"$CM_SUBSCRIPTION_ID\" -l eastus --sku Standard_LRS --kind StorageV2"
  recommend "Then: az storage container create --account-name \"$CM_STORAGE\" -n \"$CONTAINER\" --auth-mode login"
fi

section "Cost export"
if az costmanagement export show --name "$CM_EXPORT_NAME" --scope "$EXPORT_SCOPE" --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
  green "Cost export exists: $CM_EXPORT_NAME at scope $EXPORT_SCOPE"
  az costmanagement export show --name "$CM_EXPORT_NAME" --scope "$EXPORT_SCOPE" --subscription "$SUBSCRIPTION_ID" \
    --query "{name:name, scheduleStatus:properties.schedule.status, recurrence:properties.schedule.recurrence}" -o table 2>/dev/null || true
else
  red "Cost export not found: $CM_EXPORT_NAME at scope $EXPORT_SCOPE"
  info "List exports: az costmanagement export list --scope \"$EXPORT_SCOPE\" --subscription \"$SUBSCRIPTION_ID\" -o table"
  recommend "Create the export (scope = \$ARO_RG, destination = storage account):"
  recommend "  az extension add --name costmanagement"
  recommend "  EXPORT_FROM=\$(date -u -v+1d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '+1 day' +%Y-%m-%dT00:00:00Z)"
  recommend "  EXPORT_TO=\$(date -u -v+2y +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '+2 years' +%Y-%m-%dT00:00:00Z)"
  recommend "  az costmanagement export create --name \"$CM_EXPORT_NAME\" --scope \"$EXPORT_SCOPE\" --subscription \"$SUBSCRIPTION_ID\" \\"
  recommend "    --type ActualCost --timeframe MonthToDate --storage-account-id \"$STORAGE_ID\" \\"
  recommend "    --storage-container \"$CONTAINER\" --storage-directory daily --recurrence Daily \\"
  recommend "    --recurrence-period from=\"\$EXPORT_FROM\" to=\"\$EXPORT_TO\" --schedule-status Active"
fi

section "Export blobs in storage"
if KEY=$(az storage account keys list -g "$CM_RG" -n "$CM_STORAGE" --subscription "$CM_SUBSCRIPTION_ID" --query '[0].value' -o tsv 2>/dev/null); then
  BLOB_COUNT=$(az storage blob list --account-name "$CM_STORAGE" --container-name "$CONTAINER" \
    --account-key "$KEY" --query "length(@)" -o tsv 2>/dev/null || echo "0")
  if [[ "${BLOB_COUNT:-0}" -gt 0 ]]; then
    green "Found $BLOB_COUNT blob(s) in container '$CONTAINER'"
    az storage blob list --account-name "$CM_STORAGE" --container-name "$CONTAINER" \
      --account-key "$KEY" --query "[].{name:name, modified:properties.lastModified}" -o table 2>/dev/null | head -10
  else
    yellow "No blobs in container '$CONTAINER' yet — export may not have run (wait up to 24h or Run now in portal)"
    recommend "Portal: Cost Management → Exports → \"$CM_EXPORT_NAME\" → Run now."
    recommend "First scheduled run may take up to 24h after export creation."
    recommend "Hybrid Console Cloud integration stays Unavailable until at least one blob exists."
  fi
else
  red "Could not read storage account keys"
  recommend "Grant yourself Contributor or Storage Account Key Operator on: $STORAGE_ID"
  recommend "Or list blobs with login auth after granting Storage Blob Data Reader to your user."
fi

section "Service principal role assignments"
if az ad sp show --id "$AZ_CLIENT_ID" >/dev/null 2>&1; then
  green "Service principal exists: $AZ_CLIENT_ID"
else
  red "Service principal not found: $AZ_CLIENT_ID"
  recommend "Verify AZ_CLIENT_ID matches the Client ID from Hybrid Console → Settings → Integrations → Cloud tab."
  recommend "If missing, create SP — see docs/cost-management/aro_hybrid_cost_management_guide.md Step 2."
fi

SP_OBJECT_ID=$(az ad sp show --id "$AZ_CLIENT_ID" --query id -o tsv 2>/dev/null || true)
ROLES=$(az role assignment list --all --assignee-object-id "$SP_OBJECT_ID" --query "[].{role:roleDefinitionName, scope:scope}" -o tsv 2>/dev/null || true)
STORAGE_ROLES=$(az role assignment list --scope "$STORAGE_ID" --assignee-object-id "$SP_OBJECT_ID" --query "[].roleDefinitionName" -o tsv 2>/dev/null || true)
EXPORT_ROLES=$(az role assignment list --scope "$EXPORT_SCOPE" --assignee-object-id "$SP_OBJECT_ID" --query "[].roleDefinitionName" -o tsv 2>/dev/null || true)
info "Role assignments for SP:"
echo "$ROLES" | while read -r line; do [[ -n "$line" ]] && info "  $line"; done
[[ -n "$STORAGE_ROLES" ]] && info "  (storage scope) $STORAGE_ROLES"
[[ -n "$EXPORT_ROLES" ]] && info "  (export scope) $EXPORT_ROLES"

if echo "$ROLES$STORAGE_ROLES" | grep -q "Storage Blob Data Reader"; then
  green "Storage Blob Data Reader assigned (storage scope)"
else
  red "Missing Storage Blob Data Reader on storage account ($STORAGE_ID)"
  recommend "Grant blob read on the storage account (required for Red Hat to read export CSVs):"
  recommend "  az role assignment create --assignee \"$AZ_CLIENT_ID\" --role \"Storage Blob Data Reader\" --scope \"$STORAGE_ID\""
fi

if echo "$ROLES$EXPORT_ROLES" | grep -q "Cost Management Reader"; then
  green "Cost Management Reader assigned (export scope)"
else
  red "Missing Cost Management Reader on export scope ($ARO_RG)"
  recommend "Grant cost export read on the cluster resource group:"
  recommend "  az role assignment create --assignee \"$AZ_CLIENT_ID\" --role \"Cost Management Reader\" --scope \"$EXPORT_SCOPE\""
fi

section "Hybrid Cloud Console values (verify match)"
info "Cloud tab integration wizard should use:"
info "  Scope level:           Resource group"
info "  Resource group name:   $CM_RG  (storage RG — NOT necessarily $ARO_RG)"
info "  Storage account:       $CM_STORAGE"
info "  Cost export name:      $CM_EXPORT_NAME"
info "  Subscription ID:       $SUBSCRIPTION_ID  (export scope subscription — NOT storage subscription if cross-sub)"
info "  Storage subscription:  $CM_SUBSCRIPTION_ID  (where storage account lives)"
info "  Client ID:             $AZ_CLIENT_ID"
if [[ "$CM_SUBSCRIPTION_ID" != "$SUBSCRIPTION_ID" ]]; then
  yellow "Cross-subscription: wizard Subscription ID must be export scope sub ($SUBSCRIPTION_ID), not storage sub ($CM_SUBSCRIPTION_ID)"
  recommend "Hybrid Console Subscription ID = export scope ($SUBSCRIPTION_ID). Storage lives in $CM_SUBSCRIPTION_ID — do not swap these."
fi
info "If status is Unavailable: Edit integration (do not add duplicate) after fixing above"

if [[ "$FAIL" -gt 0 ]]; then
  recommend "After fixing Azure side, Edit the existing Cloud integration in Hybrid Console (Settings → Integrations → Cloud). Do not Add — that causes duplicate errors."
fi

section "Summary"
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo "---"
echo "Send this full output if sharing validation results."

if [[ ${#RECOMMENDATIONS[@]} -gt 0 ]]; then
  section "Recommendations"
  for i in "${!RECOMMENDATIONS[@]}"; do
    echo "$((i + 1)). ${RECOMMENDATIONS[$i]}"
  done
fi

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
