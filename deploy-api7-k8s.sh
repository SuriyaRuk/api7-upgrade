#!/usr/bin/env bash
# =============================================================================
# API7 Enterprise — Kubernetes Deployment Script
# Version   : 3.8.11
# Database  : Built-in PostgreSQL  (postgresql.builtin: true)
# Charts    : api7/api7ee3  (Control Plane)
#             api7/gateway  (Data Plane)
#
# Usage:
#   ./deploy-api7-k8s.sh [cp | dp | status | uninstall]
#
#   cp        — Install/upgrade the Control Plane only           (default)
#   dp        — Install/upgrade the Data Plane only
#               (requires TLS certs already created — see Step 3)
#   status    — Show pod & service status
#   uninstall — Remove all resources (including PVCs!)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
# APP_VERSION = API7 Enterprise application version (used for image tags).
# This is the "APP VERSION" column in `helm search repo --versions`,
# NOT the chart version. The script resolves the matching chart version
# automatically at runtime.
APP_VERSION="3.8.11"

NAMESPACE="api7"
HELM_REPO_NAME="api7"
HELM_REPO_URL="https://charts.api7.ai"

# Control Plane
CP_RELEASE="api7ee3"
CP_CHART="${HELM_REPO_NAME}/api7ee3"

# Data Plane
DP_RELEASE="api7-ee-3-gateway"
DP_CHART="${HELM_REPO_NAME}/gateway"
DP_SECRET_NAME="api7-ee-3-gateway-tls"   # Secret created from dashboard-generated certs
GATEWAY_GROUP_SHORT_ID="default"          # Change if using a non-default gateway group
DP_REPLICA_COUNT="1"

# Built-in PostgreSQL
PG_STORAGE_SIZE="10Gi"
PG_STORAGE_CLASS=""           # Leave blank to use cluster-default StorageClass

# Dashboard service type: ClusterIP (port-forward) | LoadBalancer | NodePort
DASHBOARD_SVC_TYPE="ClusterIP"

# ---------------------------------------------------------------------------
# COLORS / LOGGING
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
log_step()  { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }

banner() {
    echo ""
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD}  API7 Enterprise ${APP_VERSION} — Kubernetes Deployment${NC}"
    echo -e "${BOLD}  Database  : Built-in PostgreSQL (builtin)${NC}"
    echo -e "${BOLD}  Namespace : ${NAMESPACE}${NC}"
    echo -e "${BOLD}  Action    : ${1}${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# RESOLVE CHART VERSION BY APP VERSION
# Helm --version refers to the *chart* version (e.g. 1.2.3), not the
# application version (e.g. 3.8.11).  This function searches the repo index
# for the chart version whose APP VERSION column matches APP_VERSION.
# ---------------------------------------------------------------------------
resolve_chart_version() {
    local chart="$1"          # e.g. api7/api7ee3
    local app_ver="$2"        # e.g. 3.8.11

    # helm search repo output (tabular):
    #   NAME            CHART VERSION   APP VERSION   DESCRIPTION
    #   api7/api7ee3    1.2.3           3.8.11        ...
    local chart_ver
    chart_ver=$(helm search repo "$chart" --versions 2>/dev/null \
        | awk -v av="$app_ver" 'NR>1 && $3==av { print $2; exit }')

    if [[ -z "$chart_ver" ]]; then
        log_warn "No chart found for ${chart} with appVersion=${app_ver}."
        log_info  "Available versions:"
        helm search repo "$chart" --versions 2>/dev/null | head -10 || true
        log_error "Set APP_VERSION to a value listed above, or leave --version out to use latest."
    fi

    echo "$chart_ver"
}

# ---------------------------------------------------------------------------
# PREFLIGHT CHECKS
# ---------------------------------------------------------------------------
preflight() {
    log_step "Preflight Checks"
    for cmd in kubectl helm; do
        command -v "$cmd" &>/dev/null \
            || log_error "'$cmd' not found. Install it before running this script."
        log_info "$(command -v $cmd) — $(${cmd} version --short 2>/dev/null | head -1)"
    done
    kubectl cluster-info &>/dev/null \
        || log_error "Cannot reach the Kubernetes cluster. Check your KUBECONFIG."
    log_info "Cluster: $(kubectl config current-context)"
    log_ok "Preflight passed."
}

# ---------------------------------------------------------------------------
# HELM REPO
# ---------------------------------------------------------------------------
setup_helm_repo() {
    log_step "Helm Repository"
    if helm repo list 2>/dev/null | grep -q "^${HELM_REPO_NAME}[[:space:]]"; then
        log_info "Repo '${HELM_REPO_NAME}' exists — updating..."
    else
        log_info "Adding repo: ${HELM_REPO_URL}"
        helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL"
    fi
    helm repo update "$HELM_REPO_NAME"
    log_info "Available api7ee3 chart versions:"
    helm search repo "${HELM_REPO_NAME}/api7ee3" --versions | head -6 || true
    log_ok "Helm repo ready."
}

# ---------------------------------------------------------------------------
# NAMESPACE
# ---------------------------------------------------------------------------
create_namespace() {
    log_step "Namespace"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    log_ok "Namespace '${NAMESPACE}' ready."
}

# ---------------------------------------------------------------------------
# CONTROL PLANE — built-in PostgreSQL
# ---------------------------------------------------------------------------
deploy_cp() {
    log_step "Control Plane — helm upgrade --install ${CP_RELEASE}"

    # Resolve chart version that ships appVersion = APP_VERSION
    log_info "Resolving chart version for appVersion=${APP_VERSION}..."
    local CP_CHART_VER
    CP_CHART_VER=$(resolve_chart_version "$CP_CHART" "$APP_VERSION")
    log_ok "Chart version resolved: ${CP_CHART_VER}  (appVersion=${APP_VERSION})"

    # Build storage-class line only when set
    local sc_line=""
    [[ -n "$PG_STORAGE_CLASS" ]] && sc_line="    storageClass: \"${PG_STORAGE_CLASS}\""

    local TMPVAL
    TMPVAL=$(mktemp /tmp/api7-cp-values-XXXXXX.yaml)
    trap 'rm -f "$TMPVAL"' RETURN

    cat > "$TMPVAL" <<YAML
# cp-values.yaml — auto-generated by deploy-api7-k8s.sh
# Built-in PostgreSQL evaluation setup (see Step 4 in official docs)

postgresql:
  builtin: true
  primary:
    persistence:
      enabled: true
      size: ${PG_STORAGE_SIZE}
$([ -n "$sc_line" ] && echo "$sc_line" || true)

dashboard_service:
  type: ${DASHBOARD_SVC_TYPE}
YAML

    log_info "Values file:"
    echo "---"
    cat "$TMPVAL"
    echo "---"

    helm upgrade --install "$CP_RELEASE" "$CP_CHART" \
        --namespace "$NAMESPACE" \
        --version   "$CP_CHART_VER" \
        --values    "$TMPVAL" \
        --timeout   15m \
        --wait

    log_ok "Control Plane deployed."
    echo ""

    # Wait for CP pods
    log_info "Waiting for CP pods to be Ready (timeout 15 min)..."
    kubectl -n "$NAMESPACE" wait \
        --for=condition=Ready pod \
        -l app.kubernetes.io/name=api7ee3 \
        --timeout=900s
    log_ok "All CP pods are Ready."

    # Show services
    log_info "Control Plane services:"
    kubectl get svc -n "$NAMESPACE" -l app.kubernetes.io/name=api7ee3 -o wide

    echo ""
    echo -e "${BOLD}${GREEN}Next steps after CP is up:${NC}"
    echo "  1. Port-forward the dashboard:"
    echo "       kubectl -n ${NAMESPACE} port-forward svc/${CP_RELEASE}-dashboard 7443:7443"
    echo "  2. Open https://localhost:7443  (default: admin / admin)"
    echo "  3. Activate your license."
    echo "  4. Set DP Manager address: https://${CP_RELEASE}-dp-manager:7943"
    echo "  5. Generate mTLS certs from the Dashboard → Gateway Instances."
    echo "  6. Run:  $0 dp   (after placing cert files in /tmp/)"
    echo ""
}

# ---------------------------------------------------------------------------
# DATA PLANE — requires TLS secret already created
# ---------------------------------------------------------------------------
deploy_dp() {
    log_step "Data Plane — helm upgrade --install ${DP_RELEASE}"

    # Validate the mTLS secret exists
    if ! kubectl get secret "$DP_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        log_warn "Secret '${DP_SECRET_NAME}' not found in namespace '${NAMESPACE}'."
        echo ""
        echo "Create it first from the dashboard-generated certificates:"
        echo "  kubectl create secret generic ${DP_SECRET_NAME} \\"
        echo "    --from-file=tls.crt=/tmp/tls.crt \\"
        echo "    --from-file=tls.key=/tmp/tls.key \\"
        echo "    --from-file=ca.crt=/tmp/ca.crt \\"
        echo "    -n ${NAMESPACE}"
        echo ""
        log_error "Aborting DP deployment — secret missing."
    fi

    local TMPVAL
    TMPVAL=$(mktemp /tmp/api7-dp-values-XXXXXX.yaml)
    trap 'rm -f "$TMPVAL"' RETURN

    cat > "$TMPVAL" <<YAML
# dp-values.yaml — auto-generated by deploy-api7-k8s.sh

etcd:
  auth:
    tls:
      enabled: true
      existingSecret: ${DP_SECRET_NAME}
      certFilename: tls.crt
      certKeyFilename: tls.key
      verify: true
  host:
    - https://${CP_RELEASE}-dp-manager:7943

gateway:
  tls:
    existingCASecret: ${DP_SECRET_NAME}
    certCAFilename: ca.crt

apisix:
  extraEnvVars:
    - name: API7_GATEWAY_GROUP_SHORT_ID
      value: ${GATEWAY_GROUP_SHORT_ID}
  replicaCount: ${DP_REPLICA_COUNT}
  image:
    repository: api7/api7-ee-3-gateway
    tag: "${APP_VERSION}"
YAML

    log_info "Values file:"
    echo "---"
    cat "$TMPVAL"
    echo "---"

    # Resolve chart version for the gateway chart
    log_info "Resolving gateway chart version for appVersion=${APP_VERSION}..."
    local DP_CHART_VER
    DP_CHART_VER=$(resolve_chart_version "$DP_CHART" "$APP_VERSION")
    log_ok "Gateway chart version resolved: ${DP_CHART_VER}  (appVersion=${APP_VERSION})"

    helm upgrade --install "$DP_RELEASE" "$DP_CHART" \
        --namespace "$NAMESPACE" \
        --version   "$DP_CHART_VER" \
        --values    "$TMPVAL" \
        --timeout   10m \
        --wait

    log_ok "Data Plane deployed."

    # Wait for DP pods
    log_info "Waiting for gateway pods to be Ready (timeout 10 min)..."
    kubectl -n "$NAMESPACE" wait \
        --for=condition=Ready pod \
        -l app.kubernetes.io/name=gateway \
        --timeout=600s
    log_ok "All gateway pods are Ready."

    log_info "Gateway services:"
    kubectl get svc -n "$NAMESPACE" -l app.kubernetes.io/name=gateway

    echo ""
    echo -e "${BOLD}${GREEN}Smoke test:${NC}"
    echo "  kubectl -n ${NAMESPACE} port-forward svc/${DP_RELEASE}-gateway 9080:80"
    echo "  curl -i http://127.0.0.1:9080/    # expect HTTP 404 (no routes yet)"
    echo ""
}

# ---------------------------------------------------------------------------
# STATUS
# ---------------------------------------------------------------------------
show_status() {
    log_step "Deployment Status — namespace: ${NAMESPACE}"

    echo ""
    log_info "Pods:"
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "  (none)"

    echo ""
    log_info "Services:"
    kubectl get svc -n "$NAMESPACE" -o wide 2>/dev/null || echo "  (none)"

    echo ""
    log_info "Helm releases:"
    helm list -n "$NAMESPACE" 2>/dev/null || echo "  (none)"
}

# ---------------------------------------------------------------------------
# UNINSTALL
# ---------------------------------------------------------------------------
uninstall_all() {
    log_warn "This will delete ALL API7 resources including PVCs (data loss!)."
    read -rp "Type 'yes' to confirm: " confirm
    [[ "$confirm" == "yes" ]] || { log_info "Aborted."; exit 0; }

    log_info "Uninstalling Helm releases..."
    helm uninstall "$DP_RELEASE" -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall "$CP_RELEASE" -n "$NAMESPACE" 2>/dev/null || true

    log_warn "Deleting PVCs..."
    kubectl delete pvc -n "$NAMESPACE" --all --ignore-not-found

    log_warn "Deleting namespace '${NAMESPACE}'..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found

    log_ok "Uninstall complete."
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
ACTION="${1:-cp}"
banner "$ACTION"

case "$ACTION" in
    cp)
        preflight
        setup_helm_repo
        create_namespace
        deploy_cp
        ;;
    dp)
        preflight
        deploy_dp
        ;;
    status)
        show_status
        ;;
    uninstall)
        uninstall_all
        ;;
    *)
        echo "Usage: $0 [cp | dp | status | uninstall]"
        echo ""
        echo "  cp        Install/upgrade Control Plane with built-in PostgreSQL"
        echo "  dp        Install/upgrade Data Plane (certs must exist first)"
        echo "  status    Show pods, services, and Helm releases"
        echo "  uninstall Remove everything (namespace + PVCs)"
        exit 1
        ;;
esac
