# Cost Management validation from a bastion host

Use this when validating a **private ARO cluster** from a bastion host. Azure subscription validation requires separate access with the Azure CLI — see [`scripts/validate-azure.sh`](scripts/validate-azure.sh).

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

## Step 3 — Hybrid Cloud Console checks

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

If **Unavailable**: run [`validate-azure.sh`](scripts/validate-azure.sh) against the Azure subscription, fix reported issues, then **Edit** the integration (do not add a duplicate).

### End-to-end sign-off

- [ ] `./validate-cluster.sh` → PASS (or WARN only for upload timing)
- [ ] `./validate-azure.sh` → PASS (requires Azure CLI access to the subscription)
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
export CM_RG="<storage-resource-group>"
export CM_STORAGE="<storage-account>"
export CM_EXPORT_NAME="<export-name>"
export AZ_CLIENT_ID="<service-principal-client-id>"

./validate-azure.sh
```

Or individual commands:

```bash
az costmanagement export list \
  --scope "/subscriptions/<sub-id>/resourceGroups/<aro-rg>" -o table
az role assignment list --assignee "<client-id>" -o table
```

---

## Related

- [Main setup guide](aro_hybrid_cost_management_guide.md)
- [Cluster validation script](scripts/validate-cluster.sh)
- [Azure validation script](scripts/validate-azure.sh)
