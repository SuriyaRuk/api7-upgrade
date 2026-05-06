# API7 Enterprise — Kubernetes Install & Upgrade Guide

## Overview

| Script | Version | Purpose |
|--------|---------|---------|
| `deploy-api7-k8s.sh` | 3.8.11 | Fresh install — Control Plane + Data Plane |
| `upgrade-api7-3.9.10.sh` | 3.9.10 | Upgrade existing install — CP + DP |

**Architecture:**
- **Control Plane (CP):** `api7/api7ee3` — Dashboard, DP Manager, built-in PostgreSQL
- **Data Plane (DP):** `api7/gateway` — API7 Gateway instances handling traffic

---

## Prerequisites

- Kubernetes ≥ 1.25
- `kubectl` ≥ 1.25 configured to your cluster
- Helm ≥ 3.14
- API7 Enterprise license ([get trial](https://api7.ai/try?product=enterprise))
- A StorageClass configured in the cluster (for PostgreSQL PVC)

---

## Part 1 — Fresh Install (v3.8.11)

### Script: `deploy-api7-k8s.sh`

```bash
chmod +x deploy-api7-k8s.sh

./deploy-api7-k8s.sh cp        # Step 1: Install Control Plane (default)
./deploy-api7-k8s.sh dp        # Step 2: Install Data Plane (after certs are ready)
./deploy-api7-k8s.sh status    # Check pod & service status
./deploy-api7-k8s.sh uninstall # Remove everything (including PVCs!)
```

### Step 1 — Install Control Plane

```bash
./deploy-api7-k8s.sh cp
```

What the script does:
1. Adds Helm repo `https://charts.api7.ai`
2. Creates namespace `api7`
3. Resolves the chart version that ships appVersion `3.8.11`
4. Deploys `api7/api7ee3` with built-in PostgreSQL (`postgresql.builtin: true`, 10Gi PVC)
5. Waits for all CP pods to be `Ready`

**Key configuration (edit at top of script):**

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_VERSION` | `3.8.11` | API7 app version |
| `NAMESPACE` | `api7` | Kubernetes namespace |
| `PG_STORAGE_SIZE` | `10Gi` | PostgreSQL PVC size |
| `PG_STORAGE_CLASS` | _(cluster default)_ | StorageClass name |
| `DASHBOARD_SVC_TYPE` | `ClusterIP` | `ClusterIP` / `LoadBalancer` / `NodePort` |

### Step 2 — Access Dashboard & Generate Certs

After CP is up, port-forward the dashboard:

```bash
kubectl -n api7 port-forward svc/api7ee3-dashboard 7443:7443
```

Open **https://localhost:7443** → login with `admin / admin` → set new password → activate license.

Then navigate to **Gateway Settings** and set DP Manager address:
```
https://api7ee3-dp-manager:7943
```

### Step 3 — Generate mTLS Certificates

In the Dashboard go to **Gateway Groups → default → Gateway Instances → Add Gateway Instance → Kubernetes**.

The dashboard generates:
- `tls.crt` — Data Plane TLS certificate
- `tls.key` — Data Plane TLS private key
- `ca.crt` — CA certificate for CP verification

Save the cert files to `/tmp/`, then create the Kubernetes secret:

```bash
kubectl create secret generic api7-ee-3-gateway-tls \
  --from-file=tls.crt=/tmp/tls.crt \
  --from-file=tls.key=/tmp/tls.key \
  --from-file=ca.crt=/tmp/ca.crt \
  -n api7
```

### Step 4 — Install Data Plane

```bash
./deploy-api7-k8s.sh dp
```

What the script does:
1. Verifies `api7-ee-3-gateway-tls` secret exists
2. Resolves gateway chart version for appVersion `3.8.11`
3. Deploys `api7/gateway` with mTLS pointing to CP (`api7ee3-dp-manager:7943`)
4. Waits for gateway pods to be `Ready`

### Step 5 — Smoke Test

```bash
kubectl -n api7 port-forward svc/api7-ee-3-gateway-gateway 9080:80
curl -i http://127.0.0.1:9080/
# Expected: HTTP 404 (gateway running, no routes configured yet)
```

### Control Plane Services Reference

| Service | Port | Purpose |
|---------|------|---------|
| `api7ee3-dashboard` | 7443 | Dashboard UI (HTTPS) |
| `api7ee3-dashboard` | 7080 | Dashboard (HTTP) |
| `api7ee3-dp-manager` | 7943 | DP Manager mTLS endpoint |
| `api7ee3-dp-manager` | 7900 | DP Manager HTTP endpoint |
| `api7ee3-developer-portal` | 4321 | Developer Portal |

---

## Part 2 — Upgrade to v3.9.10

### Script: `upgrade-api7-3.9.10.sh`

```bash
chmod +x upgrade-api7-3.9.10.sh

./upgrade-api7-3.9.10.sh all     # Upgrade CP then DP (default)
./upgrade-api7-3.9.10.sh cp      # Upgrade Control Plane only
./upgrade-api7-3.9.10.sh dp      # Upgrade Data Plane only
./upgrade-api7-3.9.10.sh status  # Show current versions & pods
```

### Upgrade Strategy

The script uses a **safe values merge pattern** instead of `--reuse-values`:

```
helm get values <release>  →  current-values.yaml   # export existing user config
helm upgrade -f current-values.yaml                 # new chart fills in new keys with defaults
             -f override.yaml                       # pin image tag on top
```

This prevents `nil pointer` errors when the new chart version adds new value keys (e.g., `file_server.enabled` in 3.9.10).

Uses `--rollback-on-failure` (replaces deprecated `--atomic`) to auto-rollback if upgrade fails.

### Upgrade Order

**Always upgrade CP before DP.** The script enforces this when using `all`.

```bash
# Recommended: upgrade both in correct order
./upgrade-api7-3.9.10.sh all
```

### What the Upgrade Script Does

**CP upgrade:**
1. Resolves chart version for appVersion `3.9.10`
2. Exports current CP values with `helm get values`
3. Runs `helm upgrade` with exported values + new chart version
4. Waits for all CP pods to be `Ready`

**DP upgrade:**
1. Verifies mTLS secret still exists
2. Resolves gateway chart version for appVersion `3.9.10`
3. Exports current DP values
4. Runs `helm upgrade` with exported values + image tag override to `3.9.10`
5. Waits for all gateway pods to be `Ready`

---

## Troubleshooting

### Chart version not found

```
Error: chart "api7ee3" matching 3.x.x not found
```

The `--version` flag expects the **chart version**, not the app version. The scripts auto-resolve this — run `helm repo update api7` and retry. To see available versions:

```bash
helm search repo api7/api7ee3 --versions
helm search repo api7/gateway --versions
```

### nil pointer evaluating .Values.xxx.enabled

Caused by `--reuse-values` on a new chart that added new value keys. The upgrade script avoids this by using `helm get values` + `-f` instead. If hit manually, add the missing key:

```bash
helm upgrade ... --set file_server.enabled=false
```

### Pods stuck in Pending

```bash
kubectl describe pod <pod-name> -n api7
kubectl get events -n api7 --sort-by=.lastTimestamp
kubectl get storageclass   # check StorageClass exists for PVCs
```

### CP pods restarting on fresh install

Normal behaviour — `dp-manager` and `developer-portal` may briefly restart while the built-in PostgreSQL image is still pulling. Wait for `api7-postgresql-0` to reach `1/1 Running` then all CP pods will stabilise automatically.

### DP cannot connect to CP

```bash
# 1. Verify secret has all three files
kubectl get secret api7-ee-3-gateway-tls -n api7 -o json | jq '.data | keys'
# Expected: ["ca.crt", "tls.crt", "tls.key"]

# 2. Check DNS resolution from DP pod
kubectl exec -n api7 <gateway-pod> -- nslookup api7ee3-dp-manager

# 3. Check DP pod logs
kubectl logs -n api7 -l app.kubernetes.io/name=gateway --tail=50
```

### Useful Commands

```bash
# Pod status
kubectl get pods -n api7 -o wide

# Helm release versions
helm list -n api7

# CP dashboard logs
kubectl logs -f deploy/api7ee3-dashboard -n api7

# DP gateway logs
kubectl logs -f -l app.kubernetes.io/name=gateway -n api7

# Rollback CP to previous version
helm rollback api7ee3 -n api7

# Rollback DP to previous version
helm rollback api7-ee-3-gateway -n api7
```
