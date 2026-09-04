# Kubernetes Delivery Platform

A production-grade Kubernetes delivery platform that packages stateless web services
and asynchronous workers as Helm charts, layers environment-specific configuration
with Kustomize overlays, and ships everything through a hardened GitHub Actions
pipeline with multi-arch container builds, SBOM/provenance attestation, Trivy
image scanning, and progressive deployment strategies.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Repository Layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Helm Chart Reference](#helm-chart-reference)
- [Deployment Strategies](#deployment-strategies)
  - [Rolling Update (default)](#rolling-update-default)
  - [Blue/Green](#bluegreen)
  - [Canary](#canary)
- [Kustomize Overlays](#kustomize-overlays)
- [CI/CD Pipeline](#cicd-pipeline)
- [Rollback](#rollback)
- [Operational Runbook](#operational-runbook)
- [License](#license)

---

## Architecture Overview

The platform treats every workload as a versioned, templated Kubernetes release.
Two reusable Helm charts — `web-service` (stateless, fronted by Ingress) and
`worker-service` (headless, longer graceful-shutdown) — encode the full set of
production defaults: resource quotas, liveness/readiness/startup probes,
HorizontalPodAutoscalers, Prometheus `ServiceMonitor` scrapes, pod security
contexts, topology spread, and affinity rules. Kustomize overlays then stamp
each chart for `dev`, `staging`, and `prod` with environment-specific replicas,
image tags, hostnames, and resource profiles. A single GitHub Actions workflow
builds multi-arch images, pushes them to GitHub Container Registry with SBOM and
provenance, scans them with Trivy, and promotes them through the environments.

```
                         ┌──────────────────────────────────────────────────────┐
                         │                   GitHub Actions                       │
                         │  build (amd64/arm64) ─► GHCR ─► Trivy ─► deploy         │
                         └───────────────┬──────────────────────────┬────────────┘
                                         │                          │
                              push to main│                 tag / manual approval
                                         ▼                          ▼
                         ┌─────────────────────────┐  ┌─────────────────────────┐
                         │        dev overlay        │  │  staging / prod overlays  │
                         │  (Kustomize, 2 replicas)  │  │  (Kustomize, 3-20 repl.) │
                         └────────────┬─────────────┘  └────────────┬─────────────┘
                                      │                              │
                                      ▼                              ▼
                         ┌──────────────────────────────────────────────────────┐
                         │                  Kubernetes Cluster                     │
                         │                                                        │
                         │   ┌──────────┐    ┌──────────┐    ┌──────────────────┐  │
                         │   │ Ingress   │───►│ web-svc   │───►│ HPA / ServiceMon │  │
                         │   │ (nginx)   │    │ (ClusterIP)│   │  (Prometheus)     │  │
                         │   └──────────┘    └────┬─────┘    └──────────────────┘  │
                         │                        │                                  │
                         │                        ▼                                  │
                         │              ┌────────────────────┐                      │
                         │              │  worker-svc (headless) │                   │
                         │              │  exec liveness, long TGS │                  │
                         │              └────────────────────┘                      │
                         │                                                        │
                         │   Namespaces: dev | staging | prod                       │
                         └──────────────────────────────────────────────────────┘
```

---

## Repository Layout

```
kubernetes-delivery-platform/
├── .github/workflows/
│   ├── build-deploy.yml        # Build, scan, and deploy pipeline
│   └── lint.yml                # YAML/Helm/Kustomize validation
├── helm/charts/
│   ├── web-service/            # Helm chart for stateless HTTP services
│   └── worker-service/         # Helm chart for async worker workloads
├── k8s/overlays/
│   ├── dev/                    # 2 replicas, small resources, dev tag
│   ├── staging/                # 3 replicas, staging hostname, HPA 3-6
│   └── prod/                   # 5 replicas, pinned digest, PDB, HPA 5-20
├── scripts/
│   ├── deploy.sh               # Helm upgrade --install with rollout check
│   ├── rollback.sh             # Interactive Helm rollback
│   └── blue-green.sh           # Blue/green slot swap via Service selector
├── README.md
├── LICENSE
└── .gitignore
```

---

## Prerequisites

| Tool      | Minimum Version | Purpose                                  |
|-----------|-----------------|------------------------------------------|
| `kubectl` | 1.27            | Cluster access and rollout verification  |
| `helm`    | 3.13            | Chart rendering and release management   |
| `kustomize` | 5.2           | Overlay rendering (or `kubectl kustomize`)|
| `docker`  | 24.0 (buildx)   | Multi-arch container builds              |
| GitHub CLI| 2.40            | Manual prod approval (optional)          |

Cluster requirements:

- A running Kubernetes cluster (1.27+) with a configured kubeconfig context.
- The [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
  installed in the `ingress-nginx` namespace (or set `ingress.className`).
- The [Prometheus Operator](https://prometheus-operator.dev/) CRDs installed if
  `serviceMonitor.enabled` is true (the `ServiceMonitor` CRD is required).
- A container registry reachable from the cluster (GHCR by default).

---

## Quick Start

```bash
# 1. Render a chart locally to inspect the generated manifests
helm template my-app helm/charts/web-service \
  --values helm/charts/web-service/values.yaml

# 2. Lint both charts
helm lint --strict helm/charts/web-service
helm lint --strict helm/charts/worker-service

# 3. Build the dev overlay with Kustomize
kubectl kustomize k8s/overlays/dev

# 4. Deploy to the dev environment
./scripts/deploy.sh dev

# 5. Check rollout status
kubectl -n dev rollout status deployment/dev-web-service
```

---

## Helm Chart Reference

### `web-service`

A general-purpose chart for stateless HTTP workloads. Renders a `Deployment`,
`Service`, `Ingress`, `HorizontalPodAutoscaler`, `ServiceMonitor`, and
`ConfigMap`.

| Value                                   | Default                          | Description                          |
|-----------------------------------------|----------------------------------|--------------------------------------|
| `image.repository`                      | `ghcr.io/org/web-service`        | Container image repository           |
| `image.tag`                             | `""` (uses `appVersion`)         | Image tag                            |
| `image.pullPolicy`                      | `IfNotPresent`                   | Kubernetes image pull policy         |
| `image.pullSecrets`                     | `[]`                             | Names of image pull secrets          |
| `replicaCount`                          | `3`                              | Desired pod count (overridden by HPA)|
| `strategy.type`                         | `RollingUpdate`                  | Deployment strategy type             |
| `strategy.rollingUpdate.maxUnavailable` | `25%`                            | Max unavailable during rollout       |
| `strategy.rollingUpdate.maxSurge`       | `25%`                            | Max surge during rollout             |
| `serviceAccount.create`                 | `true`                           | Create a dedicated ServiceAccount    |
| `service.type`                          | `ClusterIP`                      | Service type                         |
| `service.port`                          | `8080`                           | Service port                         |
| `ingress.enabled`                       | `true`                           | Create an Ingress resource           |
| `ingress.className`                     | `nginx`                          | Ingress class                        |
| `resources.requests.cpu/memory`         | `100m / 128Mi`                   | Pod resource requests                |
| `resources.limits.cpu/memory`           | `500m / 512Mi`                   | Pod resource limits                  |
| `probes.liveness/readiness/startup`     | see values                       | Probe definitions                    |
| `hpa.enabled`                           | `true`                           | Create an HPA                        |
| `hpa.minReplicas` / `hpa.maxReplicas`   | `3` / `10`                       | HPA bounds                           |
| `serviceMonitor.enabled`                | `true`                           | Create a Prometheus ServiceMonitor   |
| `affinity` / `topologySpreadConstraints`| see values                       | Scheduling constraints               |

Run `helm show values helm/charts/web-service` for the complete, documented
default values.

### `worker-service`

A chart for asynchronous, headless worker workloads. Renders a `Deployment`,
`HorizontalPodAutoscaler`, and `ConfigMap` (no `Service` or `Ingress`). Defaults
to an `exec`-based liveness probe and a longer `terminationGracePeriodSeconds`
for graceful in-flight job draining.

---

## Deployment Strategies

### Rolling Update (default)

The `web-service` chart defaults to a `RollingUpdate` strategy with `maxSurge`
and `maxUnavailable` of `25%`. The `scripts/deploy.sh` helper runs
`helm upgrade --install --atomic --wait` and then verifies the rollout with
`kubectl rollout status`, so a failed rollout is automatically rolled back by
Helm and surfaced as a non-zero exit.

```bash
./scripts/deploy.sh prod
```

### Blue/Green

`scripts/blue-green.sh` implements a two-slot blue/green deployment using Helm
release names `web-service-blue` and `web-service-green`. A `router` Service is
swapped atomically by changing its `selector` label from `slot: blue` to
`slot: green` (or vice versa). The inactive slot is left running so that an
instant rollback is a single `kubectl patch` away.

```bash
./scripts/blue-green.sh prod
# → detects active slot, deploys inactive, waits, swaps, prints rollback cmd
```

### Canary

Canary deployments are driven by Argo Rollouts (or Flagger) using the same image
artifacts produced by this platform. The recommended pattern is to keep the
`web-service` Helm chart as the source of truth for the `stable` ReplicaSet and
to layer a `Rollout` CR on top that progressively shifts traffic (e.g. 5% → 25%
→ 50% → 100%) with automated analysis gates. Canary is intentionally **not**
implemented as a shell script because safe, automated traffic shifting requires
a controller with metric-driven promotion/abort logic that a shell loop cannot
provide safely.

---

## Kustomize Overlays

| Overlay  | `namePrefix` | Replicas | Image tag           | HPA       | Extras                          |
|----------|--------------|----------|---------------------|-----------|---------------------------------|
| `dev`    | `dev-`       | 2        | `dev`               | —         | small resources, dev env vars   |
| `staging`| `staging-`   | 3        | `staging`           | 3 → 6     | staging hostname + TLS          |
| `prod`   | `prod-`      | 5        | pinned digest       | 5 → 20    | PDB, tight rollout, rev history |

Render any overlay with:

```bash
kubectl kustomize k8s/overlays/prod
```

---

## CI/CD Pipeline

The `.github/workflows/build-deploy.yml` workflow implements a secure,
promote-based delivery flow:

1. **Build** — `docker/build-push-action` with `buildx` builds `linux/amd64` and
   `linux/arm64` images for both `web-service` and `worker-service` and pushes
   them to `ghcr.io`. SBOM and SLSA provenance attestations are attached.
2. **Scan** — Trivy scans each image and fails the build on `CRITICAL` or `HIGH`
   findings. Results are uploaded to GitHub Security tab as SARIF.
3. **Deploy to dev** — triggered on every push to `main`; runs `scripts/deploy.sh dev`.
4. **Deploy to staging** — triggered on tag pushes (`v*`); runs `scripts/deploy.sh staging`.
5. **Deploy to prod** — triggered by a `workflow_dispatch` against a `prod`
   environment that requires a manual reviewer approval.

The companion `.github/workflows/lint.yml` runs on every pull request and
validates YAML with `yamllint`, lints both Helm charts with `helm lint --strict`
against production-like values, renders templates and validates them with
`kubeval`, and builds every Kustomize overlay with `kustomize build`.

---

## Rollback

```bash
# Interactive rollback — lists revisions and prompts for one
./scripts/rollback.sh prod

# Non-interactive — roll back to a specific revision
./scripts/rollback.sh prod --revision 12
```

For blue/green releases, the fastest rollback is to flip the router Service
selector back to the previous slot (the script prints the exact command):

```bash
kubectl -n prod patch service web-service-router \
  --type=json -p='[{"op":"replace","path":"/spec/selector/slot","value":"blue"}]'
```

---

## Operational Runbook

| Symptom                          | First action                                              |
|----------------------------------|-----------------------------------------------------------|
| Rollout stuck / pods pending     | `kubectl -n <env> describe pod <pod>` → check node fit     |
| CrashLoopBackOff                 | `kubectl -n <env> logs <pod> --previous` + check probes    |
| HPA not scaling                  | Confirm metrics-server is installed and CPU requests are set|
| Ingress 504s                     | Check `ingress-nginx` controller logs and readiness probe   |
| Trivy blocking a release         | Review the SARIF report; patch the image and rebuild        |

---

## License

MIT — see [LICENSE](LICENSE). Copyright (c) Balaji Peddi.
