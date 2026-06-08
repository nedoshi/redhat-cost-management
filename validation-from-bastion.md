# Cost Management validation from a bastion host

Use this when validating a **private ARO cluster** from a bastion host. Azure subscription validation requires **separate** access with the Azure CLI (usually a workstation with `az login`, not the bastion) — see [`scripts/validate-azure.sh`](scripts/validate-azure.sh).

| Access | What to validate | Script |
|--------|------------------|--------|
| Bastion + `oc` | CMMO on cluster | [`scripts/validate-cluster.sh`](scripts/validate-cluster.sh) |
| Azure CLI + subscription | Export, storage, service principal | [`scripts/validate-azure.sh`](scripts/validate-azure.sh) |
| Red Hat account | Integrations status | Hybrid Cloud Console (browser) |

---

## Step 1 — Connect bastion to private ARO

```bash
# SSH to bastion
ssh user@<bastion-host>

# Copy validation script (or clone repo)
# scp docs/cost-management/scripts/validate-cluster.sh user@bastion:~/

# Log in to private ARO API (bastion must reach the private API endpoint)
oc login https://api.<cluster>.<region>.aroapp.io:6443 \
  --token=<token>   # or --username/--password

oc whoami
oc get nodes
```

Some clusters use a custom API domain (e.g. `https://api.<cluster>.<custom-domain>:6443`) instead of `.aroapp.io`. Use the API URL from your cluster install output or `az aro show`.

If `oc login` fails from bastion, fix network path to the private API first — nothing else will work.

---

## Step 2 — Run cluster validation script

```bash
chmod +x validate-cluster.sh
./validate-cluster.sh
```

Optional env vars if CMMO uses non-default names:

```bash
CMMO_NS=costmanagement-metrics-operator \
CMMO_CFG=costmanagementmetricscfg \
./validate-cluster.sh
```

**Save the output**, especially:

```
Cluster ID: <uuid>
last_upload_status: ...
last_successful_upload_time: ...
```

### Interpreting cluster script results

| Result | Meaning |
|--------|---------|
| `prometheus_connected: true` | CMMO reads Prometheus OK |
| `last_upload_status: 202 Accepted` | Metrics reaching Red Hat |
| `last_upload_status` missing | Wait up to 6h for first upload |
| Egress test FAIL | Cluster cannot reach `console.redhat.com:443` — check egress / proxy |
| CSV not Succeeded | CMMO not installed correctly |

---

## Step 3 — Run Azure validation script

Run from a machine with `az login` and access to **both** subscriptions when storage is cross-subscription (export scope sub + storage sub).

```bash
# Discover cluster RG and subscription (export scope)
az aro list -o table
az aro show -g <aro-rg> -n <cluster-name> --query "{rg:resourceGroup, sub:id}" -o table

export SUBSCRIPTION_ID="<export-scope-subscription-id>"   # where ARO_RG / cluster lives
export CM_SUBSCRIPTION_ID="<storage-subscription-id>"      # optional; omit if same as SUBSCRIPTION_ID
export ARO_RG="<cluster-resource-group>"                 # export scope RG (NOT storage RG)
export CM_RG="<storage-resource-group>"
export CM_STORAGE="<storage-account>"
export CM_EXPORT_NAME="<export-name>"                      # e.g. rh-cost-export-daily
export AZ_CLIENT_ID="<service-principal-client-id>"        # from Hybrid Console Cloud integration

chmod +x validate-azure.sh
./validate-azure.sh
```

On failure or warnings, the script prints a **Recommendations** section with copy-paste fixes.

**Finding the cost export in Azure Portal:** Exports scoped to a **resource group** (recommended for single-cluster ARO) do **not** appear on the default subscription-level Exports blade. In portal: **Cost Management → Exports → change scope** to resource group `$ARO_RG`, or search for the export name directly.

Cross-subscription storage: see [azure-cross-subscription-setup.md](azure-cross-subscription-setup.md).

---

## Step 4 — Hybrid Cloud Console checks

Browser access to [console.redhat.com](https://console.redhat.com) with a Red Hat account that has integration permissions.

### Red Hat tab (OpenShift / CMMO)

1. **Settings** → **Integrations** → **Red Hat**
2. Confirm integration exists
3. **Cluster identifier** matches Cluster ID from Step 2
4. Status = **Active** (not Unavailable / no data)

If duplicate error when adding: integration already exists — use it, don't add another.

On cluster, ensure CMMO is not re-creating the source:

```bash
oc patch costmanagementmetricsconfig costmanagementmetricscfg \
  -n costmanagement-metrics-operator --type merge -p \
  '{"spec":{"source":{"create_source":false}}}'
```

### Cloud tab (Azure billing)

1. **Settings** → **Integrations** → **Cloud**
2. Confirm Azure integration exists
3. Status = **Active**, not **Unavailable**

Wizard values must match what `validate-azure.sh` prints:

| Wizard field | Value |
|--------------|-------|
| Scope level | Resource group |
| Subscription ID | `$SUBSCRIPTION_ID` (export scope sub — **not** storage sub if cross-sub) |
| Resource group name | `$CM_RG` (where storage account lives — **not** necessarily `$ARO_RG`) |
| Storage account | `$CM_STORAGE` |
| Cost export name | `$CM_EXPORT_NAME` |
| Client ID / Secret | `$AZ_CLIENT_ID` and SP secret |

If **Unavailable**: run [`validate-azure.sh`](scripts/validate-azure.sh), fix reported issues (including **Run now** on the export if no blobs exist), then **Edit** the integration (do not add a duplicate).

---

## End-to-end sign-off

- [ ] `./validate-cluster.sh` → PASS (or WARN only for upload timing)
- [ ] `./validate-azure.sh` → PASS or **PASSED WITH WARNINGS** (WARN for missing blobs is OK until export runs)
- [ ] Hybrid Cloud Console Red Hat tab → **Active**
- [ ] Hybrid Cloud Console Cloud tab → **Active**
- [ ] Cost Management → **OpenShift** tab shows projects (after CMMO upload)
- [ ] Cost Management → **Infrastructure** tab shows Azure costs (after export ingested, up to 24h)

---

## Quick manual checks (no scripts)

**From bastion (cluster):**

```bash
oc get clusterversion version -o jsonpath='{.spec.clusterID}{"\n"}'
oc get csv -n costmanagement-metrics-operator
oc get costmanagementmetricsconfig -n costmanagement-metrics-operator -o yaml | \
  grep -E "prometheus_connected|last_upload_status|last_successful_upload|create_source"
oc logs -n costmanagement-metrics-operator -l app=costmanagement-metrics-operator --tail=30
```

**From Azure CLI (subscription access required):**

```bash
export SUBSCRIPTION_ID="<subscription-id>"
export ARO_RG="<export-scope-resource-group>"
export CM_EXPORT_NAME="<export-name>"

# Export exists at RG scope (add --subscription if active sub differs)
az costmanagement export list \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ARO_RG}" \
  --subscription "${SUBSCRIPTION_ID}" -o table

# SP roles — use object ID; --all needed for cross-subscription assignments
SP_OID=$(az ad sp show --id "<client-id>" --query id -o tsv)
az role assignment list --all --assignee-object-id "$SP_OID" -o table
```

---

## Related

- [Main setup guide](aro_hybrid_cost_management_guide.md)
- [Cross-subscription Azure setup](azure-cross-subscription-setup.md)
- [Cluster validation script](scripts/validate-cluster.sh)
- [Azure validation script](scripts/validate-azure.sh)
