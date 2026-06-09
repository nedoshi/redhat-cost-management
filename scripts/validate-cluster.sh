#!/usr/bin/env bash
# Validate Red Hat Cost Management — cluster side (CMMO)
# Run from bastion after: oc login <private-aro-api>
set -uo pipefail

NS="${CMMO_NS:-costmanagement-metrics-operator}"
CFG="${CMMO_CFG:-costmanagementmetricscfg}"
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

print_recommendations() {
  if [[ ${#RECOMMENDATIONS[@]} -gt 0 ]]; then
    section "Recommendations"
    for i in "${!RECOMMENDATIONS[@]}"; do
      echo "$((i + 1)). ${RECOMMENDATIONS[$i]}"
    done
  fi
}

section "Prerequisites"
if ! command -v oc >/dev/null 2>&1; then
  red "oc not found — install OpenShift CLI on bastion"
  recommend "Install OpenShift CLI: https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/cli_tools/openshift-cli-getting-started"
  print_recommendations
  exit 1
fi
green "oc found: $(oc version --client 2>/dev/null | head -1)"

if ! oc whoami >/dev/null 2>&1; then
  red "Not logged in — run: oc login https://api.<cluster>.<region>.aroapp.io:6443"
  recommend "Run: oc login https://api.<cluster>.<region>.aroapp.io:6443"
  recommend "Use a cluster-admin or user with read access to costmanagement-metrics-operator namespace."
  print_recommendations
  exit 1
fi
green "Logged in as: $(oc whoami)"

if ! oc auth can-i get clusterversion >/dev/null 2>&1; then
  yellow "Limited permissions — some checks may fail (cluster-admin recommended)"
  recommend "Re-login as cluster-admin or grant read access to clusterversion and namespace $NS."
else
  green "Cluster admin access confirmed"
fi

section "Cluster identity (for Hybrid Console Red Hat tab)"
CLUSTER_ID=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || true)
if [[ -n "$CLUSTER_ID" ]]; then
  green "Cluster ID: $CLUSTER_ID"
  info "Hybrid Console → Settings → Integrations → Red Hat tab → Cluster identifier must match exactly"
else
  red "Could not read cluster ID"
  recommend "Requires cluster-admin: oc get clusterversion version -o jsonpath='{.spec.clusterID}'"
  recommend "Hybrid Console Red Hat tab → Cluster identifier must match this value exactly."
fi

section "Cost Management Metrics Operator"
if oc get csv -n "$NS" 2>/dev/null | grep -q costmanagement-metrics-operator; then
  CSV_PHASE=$(oc get csv -n "$NS" -o jsonpath='{.items[?(@.spec.displayName=="Cost Management Metrics Operator")].status.phase}' 2>/dev/null)
  if [[ "$CSV_PHASE" == "Succeeded" ]]; then
    green "CSV phase: Succeeded"
  else
    red "CSV phase: ${CSV_PHASE:-not found}"
    recommend "Check operator install: oc get csv -n $NS"
    recommend "Check subscription: oc get subscription -n $NS costmanagement-metrics-operator -o yaml"
    recommend "Operator logs: oc logs -n $NS -l app=costmanagement-metrics-operator --tail=100"
    recommend "Reinstall from OperatorHub — see docs/cost-management/aro_hybrid_cost_management_guide.md Part 1."
  fi
else
  red "Cost Management Metrics Operator not installed in namespace $NS"
  recommend "Install CMMO from OperatorHub → namespace $NS — see aro_hybrid_cost_management_guide.md Part 1."
  recommend "Quick check after install: oc get csv -n $NS -w"
fi

POD=$(oc get pods -n "$NS" -l app=costmanagement-metrics-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$POD" ]]; then
  POD_PHASE=$(oc get pod -n "$NS" "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$POD_PHASE" == "Running" ]]; then
    green "Operator pod running: $POD"
  else
    red "Operator pod phase: ${POD_PHASE:-unknown}"
    recommend "Inspect pod: oc describe pod -n $NS $POD"
    recommend "Check events: oc get events -n $NS --field-selector involvedObject.name=$POD"
    recommend "If CrashLoopBackOff on large clusters, increase operator memory — see guide Optional: large cluster tuning."
  fi
else
  red "No CMMO operator pod found in $NS"
  recommend "Check CSV and subscription: oc get csv,subscription -n $NS"
  recommend "Ensure OperatorGroup and Subscription exist — see aro_hybrid_cost_management_guide.md Part 1 CLI steps."
fi

section "CostManagementMetricsConfig"
if ! oc get costmanagementmetricsconfig "$CFG" -n "$NS" >/dev/null 2>&1; then
  red "CostManagementMetricsConfig '$CFG' not found in $NS"
  recommend "Create CostManagementMetricsConfig after CMMO install — see aro_hybrid_cost_management_guide.md Part 1."
  recommend "Example: oc get costmanagementmetricsconfig -n $NS (expect name $CFG)"
  CFG_FOUND=""
else
  green "CostManagementMetricsConfig '$CFG' exists"
  CFG_FOUND=1

  CREATE_SOURCE=$(oc get costmanagementmetricsconfig "$CFG" -n "$NS" -o jsonpath='{.spec.source.create_source}' 2>/dev/null)
  SOURCE_NAME=$(oc get costmanagementmetricsconfig "$CFG" -n "$NS" -o jsonpath='{.spec.source.name}' 2>/dev/null)
  AUTH_TYPE=$(oc get costmanagementmetricsconfig "$CFG" -n "$NS" -o jsonpath='{.spec.authentication.type}' 2>/dev/null)
  info "create_source=$CREATE_SOURCE  source.name=$SOURCE_NAME  auth.type=$AUTH_TYPE"

  if [[ "$CREATE_SOURCE" == "true" ]]; then
    yellow "create_source=true — integration auto-created; do not add duplicate on Red Hat tab"
    recommend "Hybrid Console → Settings → Integrations → Red Hat — use existing integration named \"$SOURCE_NAME\"."
    recommend "Do not click Add integration — duplicate accounts error. Edit existing row if cluster ID mismatches."
  else
    green "create_source=false — using existing Hybrid Console integration"
  fi
fi

section "CMMO status (Prometheus + upload)"
if [[ -n "${CFG_FOUND:-}" ]]; then
  PROM_CONN=$(oc get costmanagementmetricsconfig "$CFG" -n "$NS" -o jsonpath='{.status.prometheus.prometheus_connected}' 2>/dev/null)
  PROM_CFG=$(oc get costmanagementmetricsconfig "$CFG" -n "$NS" -o jsonpath='{.status.prometheus.prometheus_configured}' 2>/dev/null)
  UPLOAD_STATUS=$(oc get costmanagementmetricsconfig "$CFG" -n "$NS" -o jsonpath='{.status.upload.last_upload_status}' 2>/dev/null)
  UPLOAD_TIME=$(oc get costmanagementmetricsconfig "$CFG" -n "$NS" -o jsonpath='{.status.upload.last_successful_upload_time}' 2>/dev/null)

  if [[ "$PROM_CONN" == "true" ]]; then
    green "prometheus_connected: true"
  else
    red "prometheus_connected: ${PROM_CONN:-false/missing}"
    recommend "CMMO must reach Thanos: https://thanos-querier.openshift-monitoring.svc:9091"
    recommend "Inspect config status: oc get costmanagementmetricsconfig $CFG -n $NS -o yaml"
    recommend "Operator logs: oc logs -n $NS -l app=costmanagement-metrics-operator --tail=100"
    recommend "Large cluster: patch subscription to increase memory limits (guide → Optional: large cluster tuning)."
  fi

  if [[ "$PROM_CFG" == "true" ]]; then
    green "prometheus_configured: true"
  else
    red "prometheus_configured: ${PROM_CFG:-false/missing}"
    recommend "Verify prometheus_config in CostManagementMetricsConfig — see aro_hybrid_cost_management_guide.md sample YAML."
    recommend "Check operator logs for Prometheus scrape errors: oc logs -n $NS -l app=costmanagement-metrics-operator --tail=100"
  fi

  if [[ "$UPLOAD_STATUS" == *"202"* ]]; then
    green "last_upload_status: $UPLOAD_STATUS"
  elif [[ -n "$UPLOAD_STATUS" ]]; then
    red "last_upload_status: $UPLOAD_STATUS (expected 202 Accepted)"
    recommend "Allow cluster egress to console.redhat.com on port 443 (from operator pod)."
    recommend "If using proxy-only egress, configure OLM/CMMO proxy per OpenShift proxy docs."
    if [[ "$AUTH_TYPE" == "service-account" ]]; then
      recommend "Service-account auth: ensure SA is in a group with cost-management settings write role."
    else
      recommend "Token auth failing on ARO: switch to service-account auth — see aro_hybrid_cost_management_guide.md Part 1."
    fi
    recommend "Red Hat tab Cluster identifier must match: ${CLUSTER_ID:-<cluster ID from oc get clusterversion>}"
  else
    yellow "last_upload_status: not set yet — first upload can take up to 6 hours (upload_cycle=360)"
    recommend "Wait up to 6 hours after CostManagementMetricsConfig creation (upload_cycle=360)."
    recommend "Monitor: oc get costmanagementmetricsconfig $CFG -n $NS -o yaml | grep -E 'last_upload_status|last_successful_upload'"
  fi

  if [[ -n "$UPLOAD_TIME" ]]; then
    green "last_successful_upload_time: $UPLOAD_TIME"
  else
    yellow "No successful upload yet"
    recommend "First successful upload may take up to 6 hours — check upload_toggle: true and upload_cycle in config."
    recommend "Hybrid Console Red Hat tab shows \"no data found\" until CMMO uploads — fix prometheus/upload status first."
  fi
fi

section "Cluster egress to Red Hat (from operator pod)"
if [[ -n "${POD:-}" ]]; then
  if oc exec -n "$NS" "$POD" -- curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://console.redhat.com >/dev/null 2>&1; then
    HTTP_CODE=$(oc exec -n "$NS" "$POD" -- curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://console.redhat.com 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" =~ ^[23] ]]; then
      green "Operator pod reaches console.redhat.com (HTTP $HTTP_CODE)"
    else
      red "Operator pod cannot reach console.redhat.com (HTTP $HTTP_CODE) — check egress/firewall/proxy"
      recommend "Allow outbound HTTPS (443) from worker nodes / cluster egress to console.redhat.com."
      recommend "Private ARO: verify firewall rules and any HTTP proxy allowlist includes console.redhat.com."
      recommend "If upload still fails after egress fix, check operator logs: oc logs -n $NS $POD --tail=100"
    fi
  else
    yellow "Could not test egress from operator pod (curl may be missing in image)"
    recommend "Manually verify egress from a debug pod or check upload status in CostManagementMetricsConfig."
  fi
else
  yellow "Skipped egress test — no operator pod"
  recommend "Fix CMMO operator pod first, then re-run this script."
fi

section "Recent operator logs (last 15 lines)"
if [[ -n "${POD:-}" ]]; then
  oc logs -n "$NS" "$POD" --tail=15 2>/dev/null || yellow "Could not read logs"
else
  yellow "Skipped logs — no operator pod"
fi

section "Hybrid Cloud Console checks (manual — no Azure/customer portal access needed)"
info "1. Settings → Integrations → Red Hat tab"
info "   - Integration exists with Cluster ID: ${CLUSTER_ID:-<unknown>}"
info "   - Status: Active (not Unavailable / no data found)"
info "2. Settings → Integrations → Cloud tab"
info "   - Azure integration Active (validate with validate-azure.sh — requires Azure CLI access)"
info "3. Cost Management → OpenShift tab shows projects after CMMO uploads"
info "4. Cost Management → Infrastructure tab shows Azure costs after Azure export is ingested"

if [[ "$FAIL" -gt 0 ]]; then
  recommend "After fixing cluster-side FAIL items, confirm Hybrid Console Red Hat tab shows Active (not Unavailable)."
  recommend "Azure billing side: run validate-azure.sh from a machine with az login."
fi

section "Summary"
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo "---"
echo "Send this full output if sharing validation results."

print_recommendations

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
