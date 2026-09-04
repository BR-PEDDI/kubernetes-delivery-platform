#!/usr/bin/env bash
set -euo pipefail

# deploy.sh — Deploy a Helm release to a Kubernetes cluster
# Usage: ./scripts/deploy.sh <release-name> <environment> [chart-path]

RELEASE_NAME="${1:?Usage: deploy.sh <release-name> <environment> [chart-path]}"
ENVIRONMENT="${2:?Environment required: dev|staging|prod}"
CHART_PATH="${3:-helm/charts/web-service}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VALUES_FILE="${PROJECT_ROOT}/environments/${ENVIRONMENT}-values.yaml"

log() { echo "[$(date +'%H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

# Pre-flight checks
for cmd in helm kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || err "$cmd not found in PATH"
done

if [[ ! -d "$CHART_PATH" ]]; then
  err "Chart directory not found: $CHART_PATH"
fi

NAMESPACE="$ENVIRONMENT"

log "Deploying release '$RELEASE_NAME' to namespace '$NAMESPACE'"
log "Chart: $CHART_PATH"

# Create namespace if it doesn't exist
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  log "Creating namespace: $NAMESPACE"
  kubectl create namespace "$NAMESPACE"
fi

# Build values args
VALUES_ARGS=()
if [[ -f "$VALUES_FILE" ]]; then
  log "Using values file: $VALUES_FILE"
  VALUES_ARGS+=(--values "$VALUES_FILE")
else
  log "No environment values file found — using chart defaults"
fi

# Deploy
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --atomic \
  --timeout 5m \
  --wait \
  "${VALUES_ARGS[@]}"

log "Checking rollout status..."
kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE_NAME" --timeout=5m

log "Deployment complete!"
log "  Release:  $RELEASE_NAME"
log "  Namespace: $NAMESPACE"
log ""
log "Pods:"
kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=$RELEASE_NAME" -o wide
log ""
log "Service:"
kubectl -n "$NAMESPACE" get svc -l "app.kubernetes.io/instance=$RELEASE_NAME"
