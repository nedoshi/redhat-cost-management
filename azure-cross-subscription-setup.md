# Azure setup — storage in a different subscription

Use when the **ARO cluster** is in subscription A and the **cost export storage account** is in subscription B (same Azure AD tenant).

```
Sub A (ARO)                         Sub B (storage)
┌─────────────────────┐            ┌─────────────────────┐
│ $ARO_RG             │            │ $CM_RG              │
│  └─ ARO cluster     │            │  └─ $CM_STORAGE     │
│                     │  export    │     └─ costexport/ │
│ Cost export scope ──┼───────────►│                     │
└─────────────────────┘   CSV      └─────────────────────┘
         │                                    ▲
         │ Cost Management Reader (SP)        │ Storage Blob Data Reader (SP)
         └────────────────────────────────────┘
                    Red Hat Cost Management reads blobs
```

---

## 1. Set variables

Replace placeholders. **Both subscriptions must be in the same tenant.**

```bash
az login
export TENANT_ID="$(az account show --query tenantId -o tsv)"

# Sub A — ARO cluster + export scope
export SUBSCRIPTION_ID="<aro-subscription-id>"
export ARO_RG="<aro-cluster-resource-group>"

# Sub B — storage only
export CM_SUBSCRIPTION_ID="<storage-subscription-id>"
export CM_RG="<storage-resource-group>"
export CM_STORAGE="<storage-account-name>"          # globally unique, lowercase
export CM_EXPORT_NAME="rh-cost-export-daily"
export CM_SP_NAME="sp-rh-cost-management"
export CM_CONTAINER="costexport"

export EXPORT_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ARO_RG}"
export STORAGE_ACCOUNT_ID="/subscriptions/${CM_SUBSCRIPTION_ID}/resourceGroups/${CM_RG}/providers/Microsoft.Storage/storageAccounts/${CM_STORAGE}"
```

Verify both subscriptions:

```bash
az account set --subscription "$SUBSCRIPTION_ID"
az group show -n "$ARO_RG" -o table
az aro list -g "$ARO_RG" -o table

az account set --subscription "$CM_SUBSCRIPTION_ID"
az group show -n "$CM_RG" -o table
```

---

## 2. Create storage account (subscription B)

```bash
az account set --subscription "$CM_SUBSCRIPTION_ID"

# Use region aligned with ARO or your org standard
CM_LOCATION=$(az group show -n "$CM_RG" --query location -o tsv)

az storage account create \
  --name "$CM_STORAGE" \
  --resource-group "$CM_RG" \
  --location "$CM_LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2

az storage container create \
  --account-name "$CM_STORAGE" \
  --name "$CM_CONTAINER" \
  --auth-mode login
```

### Storage networking (if firewall required)

Azure Portal → storage account → **Networking**:

- Public network access: **Enabled from selected virtual networks and IP addresses**
- **Allow Azure services on the trusted services list to access this storage account** → ON
- Add admin/VNet rules as needed
- Request Red Hat egress IPs via support case if policy requires explicit allowlist

Cross-subscription + strict firewall is harder — test export write before Red Hat integration.

---

## 3. Create service principal (roles on both subscriptions)

The SP needs roles in **two places**:

| Role | Scope | Subscription |
|------|-------|----------------|
| Storage Blob Data Reader | `$STORAGE_ACCOUNT_ID` | B |
| Cost Management Reader | `$EXPORT_SCOPE` | A |

```bash
# Storage Blob Data Reader on Sub B storage
SP_JSON=$(az ad sp create-for-rbac \
  --name "$CM_SP_NAME" \
  --role "Storage Blob Data Reader" \
  --scopes "$STORAGE_ACCOUNT_ID" \
  --json-auth)

export AZ_CLIENT_ID=$(echo "$SP_JSON" | jq -r .clientId)
export AZ_CLIENT_SECRET=$(echo "$SP_JSON" | jq -r .clientSecret)

echo "Client ID:     $AZ_CLIENT_ID"
echo "Client Secret: $AZ_CLIENT_SECRET"
echo "Tenant ID:     $TENANT_ID"
# Save secret — not retrievable later

# Cost Management Reader on Sub A export scope
az role assignment create \
  --assignee "$AZ_CLIENT_ID" \
  --role "Cost Management Reader" \
  --scope "$EXPORT_SCOPE" \
  --subscription "$SUBSCRIPTION_ID"

# Verify
az role assignment list --assignee "$AZ_CLIENT_ID" -o table
```

---

## 4. Create cost export (subscription A → storage in B)

Export is **created in Sub A** (export scope). Destination storage is **in Sub B**.

### Option A — Azure Portal (recommended for cross-sub)

1. Switch to **subscription A** in Azure Portal.
2. **Cost Management + Billing** → **Cost Management** → **Cost exports** → **+ Create**.
3. Template: **Cost and usage details (actual)** → **Daily export of month-to-date costs**.
4. **Scope:** Resource group → `$ARO_RG` (in Sub A).
5. **Destination:**
   - **Subscription:** select **subscription B** (`$CM_SUBSCRIPTION_ID`)
   - **Resource group:** `$CM_RG`
   - **Storage account:** `$CM_STORAGE`
   - **Container:** `costexport`
   - **Directory:** `daily` (optional)
6. **Export name:** `$CM_EXPORT_NAME`
7. Create.

> Cross-sub export creation requires **Contributor or Owner** on the **destination storage account** (Sub B) so Azure can validate and assign the export managed identity.

8. After create: **Run now** once to verify blobs appear in Sub B storage.

### Option B — Azure CLI

Run from Sub A context. User needs Contributor/Owner on Sub B storage for validation.

```bash
az account set --subscription "$SUBSCRIPTION_ID"
az extension add --name costmanagement 2>/dev/null || true

EXPORT_FROM=$(date -u -v+1d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '+1 day' +%Y-%m-%dT00:00:00Z)
EXPORT_TO=$(date -u -v+2y +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '+2 years' +%Y-%m-%dT00:00:00Z)

az costmanagement export create \
  --name "$CM_EXPORT_NAME" \
  --scope "$EXPORT_SCOPE" \
  --subscription "$SUBSCRIPTION_ID" \
  --type ActualCost \
  --timeframe MonthToDate \
  --storage-account-id "$STORAGE_ACCOUNT_ID" \
  --storage-container "$CM_CONTAINER" \
  --storage-directory daily \
  --recurrence Daily \
  --recurrence-period from="$EXPORT_FROM" to="$EXPORT_TO" \
  --schedule-status Active
```

Verify export (Sub A):

```bash
az costmanagement export show \
  --name "$CM_EXPORT_NAME" \
  --scope "$EXPORT_SCOPE" \
  --subscription "$SUBSCRIPTION_ID" -o table
```

Verify blobs (Sub B):

```bash
az account set --subscription "$CM_SUBSCRIPTION_ID"

az storage blob list \
  --account-name "$CM_STORAGE" \
  --container-name "$CM_CONTAINER" \
  --auth-mode key \
  --account-key "$(az storage account keys list -g "$CM_RG" -n "$CM_STORAGE" --subscription "$CM_SUBSCRIPTION_ID" --query '[0].value' -o tsv)" \
  -o table
```

Wait up to 24h if **Run now** was not used.

---

## 5. Hybrid Cloud Console integration (Cloud tab)

[console.redhat.com](https://console.redhat.com) → **Settings** → **Integrations** → **Cloud** → **Add integration** (or **Edit** if fixing Unavailable).

| Wizard field | Value |
|--------------|-------|
| Cloud provider | Microsoft Azure |
| Application | Cost Management |
| Scope level | Resource group |
| **Subscription ID** | **`$SUBSCRIPTION_ID`** (Sub A — export scope, **not** storage sub) |
| **Resource group name** | **`$CM_RG`** (Sub B — where storage lives) |
| **Storage account name** | **`$CM_STORAGE`** |
| Cost export name | `$CM_EXPORT_NAME` |
| Tenant ID | `$TENANT_ID` |
| Client ID | `$AZ_CLIENT_ID` |
| Client Secret | `$AZ_CLIENT_SECRET` |

Common mistake: putting **Sub B** in Subscription ID — wizard wants **export scope subscription (Sub A)**.

If duplicate error: integration already exists → **Edit** existing row, don't add another.

---

## 6. Validate

```bash
export SUBSCRIPTION_ID CM_SUBSCRIPTION_ID ARO_RG CM_RG CM_STORAGE CM_EXPORT_NAME AZ_CLIENT_ID
./scripts/validate-azure.sh
```

Plus cluster validation from bastion: `./scripts/validate-cluster.sh`

Sign-off:

- [ ] Blobs in Sub B storage (`costexport` container)
- [ ] `validate-azure.sh` PASS
- [ ] Hybrid Console Cloud tab → **Active**
- [ ] Hybrid Console Red Hat tab → **Active** (CMMO)
- [ ] Cost Management data within 24h

---

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| Export create fails "Owner access needed" | Need Contributor/Owner on Sub B storage account |
| Unavailable Cloud integration | Wrong Subscription ID in wizard (used Sub B instead of Sub A) |
| Unavailable Cloud integration | Wrong `$CM_RG` / `$CM_STORAGE` / export name |
| No blobs in storage | Export not run yet; trusted MS services off; cross-sub MI permissions |
| Duplicate integration error | Row already exists — Edit, don't re-add |

---

## Related

- [Main setup guide](aro_hybrid_cost_management_guide.md)
- [Validation from bastion](validation-from-bastion.md)
- [validate-azure.sh](scripts/validate-azure.sh)
