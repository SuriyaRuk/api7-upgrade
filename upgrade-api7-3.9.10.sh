#!/usr/bin/env bash
# =============================================================================
# API7 Enterprise — Upgrade Script
# Target Version : 3.9.10  (CP + DP)
# Charts         : api7/api7ee3  (Control Plane)
#                  api7/gateway  (Data Plane)
#
# Usage:
#   ./upgrade-api7-3.9.10.sh [all | cp | dp | status]
#
#   all    — Upgrade CP first, then DP             (default)
#   cp     — Upgrade Control Plane only
#   dp     — Upgrade Data Plane only
#   status — Show current version & pod status
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
TARGET_VERSION="3.9.10"       # API7 app version to upgrade to

NAMESPACE="api7"
HELM_REPO_NAME="api7"
HELM_REPO_URL="https://charts.api7.ai"

CP_RELEASE="api7ee3"
CP_CHART="${HELM_REPO_NAME}/api7ee3"

DP_RELEASE="api7-ee-3-gateway"
DP_CHART="${HELM_REPO_NAME}/gateway"
DP_SECRET_NAME="api7-ee-3-gateway-tls"
GATEWAY_GROUP_SHORT_ID="default"

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
    echo -e "${BOLD}  API7 Enterprise — Upgrade to ${TARGET_VERSION}${NC}"
    echo -e "${BOLD}  Namespace : ${NAMESPACE}${NC}"
    echo -e "${BOLD}  Action    : ${1}${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# PREFLIGHT
# ---------------------------------------------------------------------------
preflight() {
    log_step "Preflight Checks"

    for cmd in kubectl helm; do
        command -v "$cmd" &>/dev/null \
            || log_error "'$cmd' not found. Install it before running this script."
    done

    kubectl cluster-info &>/dev/null \
        || log_error "Cannot reach the Kubernetes cluster. Check your KUBECONFIG."
    log_info "Cluster: $(kubectl config current-context)"

    # Check namespace exists
    kubectl get namespace "$NAMESPACE" &>/dev/null \
        || log_error "Namespace '${NAMESPACE}' not found. Is API7 installed?"

    log_ok "Preflight passed."
}

# ---------------------------------------------------------------------------
# HELM REPO UPDATE
# ---------------------------------------------------------------------------
update_helm_repo() {
    log_step "Helm Repository"

    if ! helm repo list 2>/dev/null | grep -q "^${HELM_REPO_NAME}[[:space:]]"; then
        log_info "Adding repo: ${HELM_REPO_URL}"
        helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL"
    fi

    helm repo update "$HELM_REPO_NAME"
    log_ok "Helm repo updated."
}

# ---------------------------------------------------------------------------
# RESOLVE CHART VERSION BY APP VERSION
# Finds the chart version whose APP VERSION column matches TARGET_VERSION.
# ---------------------------------------------------------------------------
resolve_chart_version() {
    local chart="$1"
    local app_ver="$2"

    local chart_ver
    chart_ver=$(helm search repo "$chart" --versions 2>/dev/null \
        | awk -v av="$app_ver" 'NR>1 && $3==av { print $2; exit }')

    if [[ -z "$chart_ver" ]]; then
        log_warn "No chart found for ${chart} with appVersion=${app_ver}."
        log_info  "Available versions:"
        helm search repo "$chart" --versions 2>/dev/null | head -10 || true
        log_error "Set TARGET_VERSION to a value listed in APP VERSION column above."
    fi

    echo "$chart_ver"
}

# ---------------------------------------------------------------------------
# SHOW CURRENT VERSION
# ---------------------------------------------------------------------------
show_current_versions() {
    log_info "Current installed releases:"
    helm list -n "$NAMESPACE" \
        --filter "^(${CP_RELEASE}|${DP_RELEASE})$" \
        -o table 2>/dev/null || echo "  (none)"

    echo ""
    log_info "Current pod images:"
    kubectl get pods -n "$NAMESPACE" -o jsonpath=\
'{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
        2>/dev/null | grep -E "api7" | sort || echo "  (none)"
}

# ---------------------------------------------------------------------------
# HELM VALUES STRATEGY
#
# --reuse-values  keeps ONLY user-supplied keys from the previous release.
# New keys added in the target chart get NO default → nil pointer errors.
#
# Safe pattern (works on all Helm versions):
#   1. helm get values  → export current user values to a temp file
#   2. helm upgrade -f  → apply them against the new chart
#      The new chart's defaults fill in any new keys not present in the file.
# ---------------------------------------------------------------------------
export_current_values() {
    local release="$1"
    local outfile="$2"
    log_info "Exporting current user values for release '${release}'..."
    helm get values "$release" -n "$NAMESPACE" -o yaml > "$outfile" 2>/dev/null \
        || { log_warn "No existing values found — will use chart defaults only."; echo "{}" > "$outfile"; }
    log_info "Saved to: ${outfile}"
}

# ---------------------------------------------------------------------------
# UPGRADE CONTROL PLANE
# ---------------------------------------------------------------------------
upgrade_cp() {
    log_step "Upgrade Control Plane → ${TARGET_VERSION}"

    log_info "Resolving CP chart version for appVersion=${TARGET_VERSION}..."
    local CP_CHART_VER
    CP_CHART_VER=$(resolve_chart_version "$CP_CHART" "$TARGET_VERSION")
    log_ok "CP chart version: ${CP_CHART_VER}  (appVersion=${TARGET_VERSION})"

    local CURRENT_VALS
    CURRENT_VALS=$(mktemp /tmp/api7-cp-current-XXXXXX.yaml)
    trap 'rm -f "$CURRENT_VALS"' RETURN

    export_current_values "$CP_RELEASE" "$CURRENT_VALS"

    log_info "Current values to preserve:"
    cat "$CURRENT_VALS"
    echo ""

    log_info "Running helm upgrade..."
    helm upgrade "$CP_RELEASE" "$CP_CHART" \
        --namespace          "$NAMESPACE" \
        --version            "$CP_CHART_VER" \
        --values             "$CURRENT_VALS" \
        --timeout            30m \
        --wait \
        --rollback-on-failure

    log_ok "Control Plane upgraded to ${TARGET_VERSION}."

    log_info "Waiting for CP pods to be Ready..."
    kubectl -n "$NAMESPACE" wait \
        --for=condition=Ready pod \
        -l app.kubernetes.io/name=api7ee3 \
        --timeout=1800s

    log_ok "All CP pods are Ready."
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=api7ee3
}

# ---------------------------------------------------------------------------
# UPGRADE DATA PLANE
# ---------------------------------------------------------------------------
upgrade_dp() {
    log_step "Upgrade Data Plane → ${TARGET_VERSION}"

    # Validate mTLS secret still exists
    kubectl get secret "$DP_SECRET_NAME" -n "$NAMESPACE" &>/dev/null \
        || log_error "mTLS secret '${DP_SECRET_NAME}' not found in namespace '${NAMESPACE}'."

    log_info "Resolving gateway chart version for appVersion=${TARGET_VERSION}..."
    local DP_CHART_VER
    DP_CHART_VER=$(resolve_chart_version "$DP_CHART" "$TARGET_VERSION")
    log_ok "Gateway chart version: ${DP_CHART_VER}  (appVersion=${TARGET_VERSION})"

    local CURRENT_VALS
    CURRENT_VALS=$(mktemp /tmp/api7-dp-current-XXXXXX.yaml)
    local OVERRIDE_VALS
    OVERRIDE_VALS=$(mktemp /tmp/api7-dp-override-XXXXXX.yaml)
    trap 'rm -f "$CURRENT_VALS" "$OVERRIDE_VALS"' RETURN

    # Export existing DP values (preserves mTLS, etcd host, replica count, etc.)
    export_current_values "$DP_RELEASE" "$CURRENT_VALS"

    # Override only the image tag — merged on top of current values
    cat > "$OVERRIDE_VALS" <<YAML
# Image tag override for ${TARGET_VERSION}
apisix:
  image:
    repository: api7/api7-ee-3-gateway
    tag: "${TARGET_VERSION}"
YAML

    log_info "Image tag override:"
    cat "$OVERRIDE_VALS"
    echo ""

    log_info "Running helm upgrade..."
    helm upgrade "$DP_RELEASE" "$DP_CHART" \
        --namespace          "$NAMESPACE" \
        --version            "$DP_CHART_VER" \
        --values             "$CURRENT_VALS" \
        --values             "$OVERRIDE_VALS" \
        --timeout            10m \
        --wait \
        --rollback-on-failure

    log_ok "Data Plane upgraded to ${TARGET_VERSION}."

    log_info "Waiting for gateway pods to be Ready..."
    kubectl -n "$NAMESPACE" wait \
        --for=condition=Ready pod \
        -l app.kubernetes.io/name=gateway \
        --timeout=600s

    log_ok "All gateway pods are Ready."
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=gateway
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
    kubectl get svc -n "$NAMESPACE" 2>/dev/null || echo "  (none)"

    echo ""
    log_info "Helm releases:"
    helm list -n "$NAMESPACE" 2>/dev/null || echo "  (none)"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
ACTION="${1:-all}"
banner "$ACTION"

case "$ACTION" in
    all)
        preflight
        update_helm_repo
        show_current_versions
        upgrade_cp
        upgrade_dp
        echo ""
        echo -e "${BOLD}${GREEN}============================================================${NC}"
        echo -e "${BOLD}${GREEN}  ✅  API7 Enterprise upgraded to ${TARGET_VERSION}${NC}"
        echo -e "${BOLD}${GREEN}============================================================${NC}"
        echo ""
        show_status
        ;;
    cp)
        preflight
        update_helm_repo
        upgrade_cp
        ;;
    dp)
        preflight
        update_helm_repo
        upgrade_dp
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 [all | cp | dp | status]"
        echo ""
        echo "  all    Upgrade CP then DP to ${TARGET_VERSION} (default)"
        echo "  cp     Upgrade Control Plane only"
        echo "  dp     Upgrade Data Plane only"
        echo "  status Show current pod & release status"
        exit 1
        ;;
esac
