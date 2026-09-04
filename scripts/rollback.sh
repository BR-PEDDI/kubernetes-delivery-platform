#!/usr/bin/env bash
set -euo pipefail

# rollback.sh — Roll back a Helm release to a previous revision
# Usage: ./scripts/rollback.sh <release-name> <namespace> [revision]
#        If no revision is specified, shows history and prompts interactively.

RELEASE_NAME="${1:?Usage: rollback.sh <release-name> <namespace> [revision]}"
NAMESPACE="${2:?Namespace required}"
REVISION="${3:-}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

command -v helm >/dev/null 2>&1 || err "helm not found"
command -v kubectl >/dev/null 2>&1 || err "kubectl not found"

log "Release history for '$RELEASE_NAME' in namespace '$NAMESPACE':"
helm -n "$NAMESPACE" history "$RELEASE_NAME"

if [[ -z "$REVISION" ]]; then
  echo ""
  read -rp "Enter revision to roll back to (or 'q' to quit): " REVISION
  [[ "$REVISION" == "q" ]] && exit 0
  [[ "$REVISION" =~ ^[0-9]+$ ]] || err "Invalid revision number: $REVISION"
fi

log "Rolling back $RELEASE_NAME to revision $REVISION..."
helm rollback "$RELEASE_NAME" "$REVISION" -n "$NAMESPACE" --wait --timeout 5m

log "Verifying rollout..."
kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE_NAME" --timeout=5m

log "Rollback complete: $RELEASE_NAME is at revision $REVISION"
log ""
log "Current pods:"
kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=$RELEASE_NAME"
