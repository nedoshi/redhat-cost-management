# Cost Management validation from a bastion host

Use this when you have **bastion + private ARO access** but **no customer Azure portal access**.

| Who | What | Script |
|-----|------|--------|
| **You** (platform team) | Validate CMMO on cluster | [`scripts/validate-cluster.sh`](scripts/validate-cluster.sh) |
| **Customer Azure admin** | Validate export, storage, SP roles | [`scripts/validate-azure.sh`](scripts/validate-azure.sh) |
| **Either** | Hybrid Cloud Console | Manual checks (no API from bastion) |

---

## Step 1 — Connect bastion to private ARO

```bash
# SSH to bastion (your org's method)
ssh user@<bastion-host>

# Copy validation script (or clone repo)
# scp docs/cost-management/scripts/validate-cluster.sh user@bastion:~/

# Log in to private ARO API (from bastion — must reach private API)
oc login https://api.<cluster>.<region>.aroapp.io:6443 \
  --token=<token>   # or --username/--password

oc whoami
oc get nodes
```

If `oc login` fails from bastion, fix network path to the private API first — nothing else will work.

---

## Step 2 — Run cluster validation script

```bash
chmod +x validate-cluster.sh
./validate-cluster.sh
```

Optional env vars if your CMMO config uses non-default names:

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

---

## Step 3 — Hybrid Cloud Console checks (your Red Hat login)

No bastion script — browser only.

### Red Hat tab (OpenShift / CMMO)

1. [console.redhat.com](https://console.redhat.com) → **Settings** → **Integrations** → **Red Hat**
2. Confirm integration exists
3. **Cluster identifier** = Cluster ID from Step 2 output
4. Status = **Active** (not Unavailable / no data)

If duplicate error when adding: integration already exists — use it, don't add another.

On cluster, ensure CMMO is not re-creating source:

```bash
oc patch costmanagementmetricsconfig costmanagementmetricscfg \
  -n costmanagement-metrics-operator --type merge -p \
  '{"spec":{"source":{"create_source":false}}}'
```

### Cloud tab (Azure billing)

1. **Settings** → **Integrations** → **Cloud**
2. Find integration (e.g. `azure_billing_data`)
3. Status should be **Active**, not **Unavailable**

If **Unavailable** → customer must run Azure validation (Step 4) and **Edit** integration (don't add duplicate).

---

## Step 4 — Send Azure script to customer admin

You cannot validate Azure from bastion without `az login` to the customer subscription. Send customer this checklist + script.

**Email template:**

```
Please run the attached validate-azure.sh in Azure Cloud Shell or a machine with az CLI logged into our subscription.

Required values:
  SUBSCRIPTION_ID=<id>
  ARO_RG=<cluster resource group>
  CM_RG=<storage resource group>
  CM_STORAGE=<storage account name>
  CM_EXPORT_NAME=<cost export name>
  AZ_CLIENT_ID=<service principal from Hybrid Console integration>

Example:
  export SUBSCRIPTION_ID="..."
  export ARO_RG="nddemo-rg"
  export CM_RG="rg-cost-management"
  export CM_STORAGE="nddemostorage"
  export CM_EXPORT_NAME="rh-cost-export-daily"
  export AZ_CLIENT_ID="..."
  ./validate-azure.sh

Reply with full script output.
```

Customer runs:

```bash
chmod +x validate-azure.sh

export SUBSCRIPTION_ID="<customer-sub-id>"
export ARO_RG="<aro-cluster-rg>"
export CM_RG="<storage-rg>"
export CM_STORAGE="<storage-account>"
export CM_EXPORT_NAME="<export-name>"
export AZ_CLIENT_ID="<sp-client-id>"

./validate-azure.sh 2>&1 | tee azure-validation.txt
```

---

## Step 5 — Interpret results

### Cluster script

| Result | Meaning |
|--------|---------|
| `prometheus_connected: true` | CMMO reads Prometheus OK |
| `last_upload_status: 202 Accepted` | Metrics reaching Red Hat |
| `last_upload_status` missing | Wait up to 6h for first upload |
| Egress test FAIL | Cluster cannot reach `console.redhat.com:443` — fix ARO egress / proxy |
| CSV not Succeeded | CMMO not installed correctly |

### Azure script (from customer)

| Result | Meaning |
|--------|---------|
| Export exists + blobs present | Azure side writing data |
| No blobs | Export not run yet — Run now in portal or wait 24h |
| Missing SP roles | Fix Storage Blob Data Reader + Cost Management Reader |
| `publicNetworkAccess: Disabled` | Likely blocks Red Hat — needs policy exception or Red Hat IPs |
| CM_RG ≠ ARO_RG in wizard | Common misconfig — storage RG must match where account lives |

### Hybrid Console

| Tab | Good | Bad |
|-----|------|-----|
| Red Hat | Active + matching cluster ID | Unavailable / no data / duplicate error |
| Cloud | Active | Unavailable → fix Azure, then Edit integration |

---

## Step 6 — End-to-end sign-off

All must be true:

- [ ] `./validate-cluster.sh` → PASS (or WARN only for upload timing)
- [ ] Customer `./validate-azure.sh` → PASS
- [ ] Hybrid Console Red Hat tab → **Active**
- [ ] Hybrid Console Cloud tab → **Active**
- [ ] Cost Management → **OpenShift** tab shows projects (after CMMO upload)
- [ ] Cost Management → **Infrastructure** tab shows Azure costs (after export + up to 24h)

---

## Quick manual checks (no scripts)

**Bastion only:**

```bash
oc get clusterversion version -o jsonpath='{.spec.clusterID}{"\n"}'
oc get csv -n costmanagement-metrics-operator
oc get costmanagementmetricsconfig -n costmanagement-metrics-operator -o yaml | \
  grep -E "prometheus_connected|last_upload_status|last_successful_upload|create_source"
oc logs -n costmanagement-metrics-operator -l app=costmanagement-metrics-operator --tail=30
```

**Customer Azure only:**

```bash
az costmanagement export list --scope "/subscriptions/<sub>/resourceGroups/<aro-rg>" -o table
az role assignment list --assignee "<client-id>" -o table
```

---

## Related

- [Main setup guide](aro_hybrid_cost_management_guide.md)
- [Cluster script](scripts/validate-cluster.sh)
- [Azure script](scripts/validate-azure.sh)
