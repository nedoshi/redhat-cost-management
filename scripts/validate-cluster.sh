#!/usr/bin/env bash
# Validate Red Hat Cost Management — cluster side (CMMO)
# Run from bastion after: oc login <private-aro-api>
set -uo pipefail

NS="${CMMO_NS:-costmanagement-metrics-operator}"
CFG="${CMMO_CFG:-costmanagementmetricscfg}"
PASS=0
FAIL=0
WARN=0

green()  { printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; ((PASS++)) || true; }
red()    { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; ((FAIL++)) || true; }
yellow() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; ((WARN++)) || true; }
info()   { printf '[INFO] %s\n' "$*"; }

section() { echo; echo "=== $* ==="; }

section "Prerequisites"
if ! command -v oc >/dev/null 2>&1; then
  red "oc not found — install OpenShift CLI on bastion"
  exit 1
fi
green "oc found: $(oc version --client 2>/dev/null | head -1)"

if ! oc whoami >/dev/null 2>&1; then
  red "Not logged in — run: oc login https://api.<cluster>.<region>.aroapp.io:6443"
  exit 1
fi
green "Logged in as: $(oc whoami)"

if ! oc auth can-i get clusterversion >/dev/null 2>&1; then
  yellow "Limited permissions — some checks may fail (cluster-admin recommended)"
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
fi

section "Cost Management Metrics Operator"
if oc get csv -n "$NS" 2>/dev/null | grep -q costmanagement-metrics-operator; then
  CSV_PHASE=$(oc get csv -n "$NS" -o jsonpath='{.items[?(@.spec.displayName=="Cost Management Metrics Operator")].status.phase}' 2>/dev/null)
  if [[ "$CSV_PHASE" == "Succeeded" ]]; then
    green "CSV phase: Succeeded"
  else
    red "CSV phase: ${CSV_PHASE:-not found}"
  fi
else
  red "Cost Management Metrics Operator not installed in namespace $NS"
fi

POD=$(oc get pods -n "$NS" -l app=costmanagement-metrics-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$POD" ]]; then
  POD_PHASE=$(oc get pod -n "$NS" "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$POD_PHASE" == "Running" ]]; then
    green "Operator pod running: $POD"
  else
    red "Operator pod phase: ${POD_PHASE:-unknown}"
  fi
else
  red "No CMMO operator pod found in $NS"
fi

section "CostManagementMetricsConfig"
if ! oc get costmanagementmetricsconfig "$CFG" -n "$NS" >/dev/null 2>&1; then
  red "CostManagementMetricsConfig '$CFG' not found in $NS"
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
  fi

  if [[ "$PROM_CFG" == "true" ]]; then
    green "prometheus_configured: true"
  else
    red "prometheus_configured: ${PROM_CFG:-false/missing}"
  fi

  if [[ "$UPLOAD_STATUS" == *"202"* ]]; then
    green "last_upload_status: $UPLOAD_STATUS"
  elif [[ -n "$UPLOAD_STATUS" ]]; then
    red "last_upload_status: $UPLOAD_STATUS (expected 202 Accepted)"
  else
    yellow "last_upload_status: not set yet — first upload can take up to 6 hours (upload_cycle=360)"
  fi

  if [[ -n "$UPLOAD_TIME" ]]; then
    green "last_successful_upload_time: $UPLOAD_TIME"
  else
    yellow "No successful upload yet"
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
    fi
  else
    yellow "Could not test egress from operator pod (curl may be missing in image)"
  fi
else
  yellow "Skipped egress test — no operator pod"
fi

section "Recent operator logs (last 15 lines)"
if [[ -n "${POD:-}" ]]; then
  oc logs -n "$NS" "$POD" --tail=15 2>/dev/null || yellow "Could not read logs"
fi

section "Hybrid Cloud Console checks (manual — no Azure/customer portal access needed)"
info "1. Settings → Integrations → Red Hat tab"
info "   - Integration exists with Cluster ID: ${CLUSTER_ID:-<unknown>}"
info "   - Status: Active (not Unavailable / no data found)"
info "2. Settings → Integrations → Cloud tab"
info "   - Azure integration Active (customer Azure admin validates — see validate-azure.sh)"
info "3. Cost Management → OpenShift tab shows projects after CMMO uploads"
info "4. Cost Management → Infrastructure tab shows Azure costs after customer Azure setup"

section "Summary"
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: FAILED — fix FAIL items above"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "Result: PASSED WITH WARNINGS — review WARN items; may need wait time or customer Azure validation"
  exit 0
else
  echo "Result: PASSED — cluster side looks good"
  exit 0
fi
