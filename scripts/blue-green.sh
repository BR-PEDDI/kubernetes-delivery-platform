#!/usr/bin/env bash
set -euo pipefail

# blue-green.sh — Perform a blue/green deployment via Helm
# Deploys to the inactive slot, verifies health, then atomically swaps the Service selector.
#
# Usage: ./scripts/blue-green.sh <release-name> <namespace> <chart-path>

RELEASE_NAME="${1:?Usage: blue-green.sh <release-name> <namespace> <chart-path>}"
NAMESPACE="${2:?Namespace required}"
CHART_PATH="${3:?Chart path required}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

command -v helm >/dev/null 2>&1 || err "helm not found"
command -v kubectl >/dev/null 2>&1 || err "kubectl not found"

# Determine which slot is currently active by inspecting the Service selector
get_active_slot() {
  local slot
  slot=$(kubectl -n "$NAMESPACE" get svc "$RELEASE_NAME" \
    -o jsonpath='{.metadata.annotations.slot}' 2>/dev/null || true)
  echo "${slot:-blue}"
}

ACTIVE_SLOT=$(get_active_slot)
INACTIVE_SLOT="green"
[[ "$ACTIVE_SLOT" == "green" ]] && INACTIVE_SLOT="blue"

log "Active slot:   $ACTIVE_SLOT"
log "Inactive slot: $INACTIVE_SLOT (will deploy here)"

# Deploy to the inactive slot
INACTIVE_RELEASE="${RELEASE_NAME}-${INACTIVE_SLOT}"

log "Deploying $INACTIVE_RELEASE to $INACTIVE_SLOT slot..."
helm upgrade --install "$INACTIVE_RELEASE" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --set "fullnameOverride=${INACTIVE_RELEASE}" \
  --atomic \
  --wait \
  --timeout 5m

log "Waiting for $INACTIVE_SLOT pods to be ready..."
kubectl -n "$NAMESPACE" rollout status deployment/"$INACTIVE_RELEASE" --timeout=5m

# Health check the inactive slot
log "Running health checks on $INACTIVE_SLOT slot..."
INACTIVE_IP=$(kubectl -n "$NAMESPACE" get svc "$INACTIVE_RELEASE" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

if [[ -n "$INACTIVE_IP" ]]; then
  HEALTH=$(kubectl -n "$NAMESPACE" run "health-check-${INACTIVE_SLOT}" \
    --rm -i --restart=Never --image=curlimages/curl:latest \
    -- curl -sf "http://${INACTIVE_IP}:8080/healthz" 2>/dev/null || echo "FAILED")

  if [[ "$HEALTH" == "FAILED" ]]; then
    err "Health check failed on $INACTIVE_SLOT slot — aborting cutover. Old slot ($ACTIVE_SLOT) still serving."
  fi
  log "Health check passed on $INACTIVE_SLOT slot"
else
  log "WARNING: Could not determine $INACTIVE_SLOT service IP — skipping health check"
fi

# Atomic cutover: swap the Service selector
log "Cutting over: switching Service '$RELEASE_NAME' from $ACTIVE_SLOT to $INACTIVE_SLOT..."

kubectl -n "$NAMESPACE" patch svc "$RELEASE_NAME" --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/selector/app.kubernetes.io/instance\",\"value\":\"${INACTIVE_RELEASE}\"},
  {\"op\":\"replace\",\"path\":\"/metadata/annotations/slot\",\"value\":\"${INACTIVE_SLOT}\"}
]" 2>/dev/null || {
  # If the annotation doesn't exist yet, create it
  kubectl -n "$NAMESPACE" annotate svc "$RELEASE_NAME" "slot=${INACTIVE_SLOT}" --overwrite
  kubectl -n "$NAMESPACE" patch svc "$RELEASE_NAME" --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/selector/app.kubernetes.io/instance\",\"value\":\"${INACTIVE_RELEASE}\"}
  ]"
}

log "Cutover complete. $INACTIVE_SLOT is now active."
log ""
log "Current state:"
kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance in (${RELEASE_NAME}-${ACTIVE_SLOT}, ${INACTIVE_RELEASE})"
log ""
log "To roll back instantly:"
log "  kubectl -n $NAMESPACE patch svc $RELEASE_NAME --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/selector/app.kubernetes.io/instance\",\"value\":\"${RELEASE_NAME}-${ACTIVE_SLOT}\"}]'"
log ""
read -rp "Clean up old $ACTIVE_SLOT slot? (y/N): " CLEANUP
if [[ "$CLEANUP" == "y" || "$CLEANUP" == "Y" ]]; then
  log "Uninstalling ${RELEASE_NAME}-${ACTIVE_SLOT}..."
  helm uninstall "${RELEASE_NAME}-${ACTIVE_SLOT}" -n "$NAMESPACE"
  log "Old slot cleaned up"
else
  log "Old slot ($ACTIVE_SLOT) kept for quick rollback"
fi
