# release-penpot

Helm chart that deploys [Penpot](https://penpot.app) (open-source design &
prototyping platform) on OpenShift, for development/test use.

See [INSTALL.md](INSTALL.md) for the full step-by-step walkthrough of how
this was actually installed on OpenShift Local (CRC) — including the real
problems hit along the way (a memory-constrained node, a MinIO arbitrary-UID
bug, and two ArgoCD/Helm interaction bugs) and which fixes are CRC-specific
vs. general OpenShift behavior.

The chart is self-contained: it deploys Penpot's own backend, frontend and
exporter, plus everything they need to run —

- **PostgreSQL** — Penpot's primary datastore.
- **Valkey** (Redis-compatible) — required, not optional. Penpot uses it for
  websocket/pub-sub coordination between backend instances and short-lived
  data, even with a single backend replica.
- **MinIO** (S3-compatible) — object storage for uploaded assets (images,
  exports, etc). Penpot can also use plain filesystem storage
  (`PENPOT_OBJECTS_STORAGE_BACKEND=fs`), but this chart defaults to S3/MinIO.

This chart holds no environment-specific values. Per-environment overrides
(hostname, storage sizes, resource sizing) live in
[`envirenment-penpot`](https://github.com/dragos1993/envirenment-penpot) and
are layered on top via ArgoCD's multi-source `valueFiles`, or with
`helm install -f`. The ArgoCD `Application` that wires the two together
lives in [`argocd-repo`](https://github.com/dragos1993/argocd-repo).

## Prerequisites (manual, not managed by this chart)

Secrets are intentionally **not** generated or stored by this chart or its
values repo — nothing plaintext should live in git. Before installing,
create the namespace and a Secret the chart reads via `existingSecretName`
(default `penpot-secrets`):

```bash
oc create ns penpot

PG_PASS=$(openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24)
MINIO_USER="penpot-minio"
MINIO_PASS=$(openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24)
SECRET_KEY=$(openssl rand -hex 32)

oc create secret generic penpot-secrets -n penpot \
  --from-literal=postgres-password="$PG_PASS" \
  --from-literal=minio-root-user="$MINIO_USER" \
  --from-literal=minio-root-password="$MINIO_PASS" \
  --from-literal=penpot-secret-key="$SECRET_KEY"
```

Keep these values somewhere safe (e.g. a password manager) if you need to
recreate the secret later — the chart never regenerates it.

## Install directly with Helm

```bash
helm install penpot . -n penpot -f ../envirenment-penpot/values-dev.yaml
```

Or via ArgoCD — see `argocd-repo/README.md`.

## What's in the chart

| Component | Kind | Notes |
|---|---|---|
| `penpot-postgres` | Deployment + PVC | Single replica, `Recreate` strategy. `PGDATA` set to a subdirectory of the mount to dodge the classic `lost+found`-on-fresh-PVC init failure. |
| `penpot-valkey` | Deployment | No persistence — it's a cache/pubsub broker, not a store of record. |
| `penpot-minio` | Deployment + PVC + post-install/upgrade Job | The Job runs `mc mb --ignore-existing` to create the assets bucket, since Penpot's S3 client does not create it automatically. |
| `penpot-backend` | Deployment | Talks to Postgres, Valkey and MinIO (via S3 API). |
| `penpot-frontend` | Deployment + Route | nginx serving the SPA and proxying to backend/exporter. |
| `penpot-exporter` | Deployment | Renders PDF/PNG/SVG exports by loading pages from the *frontend* (`PENPOT_INTERNAL_URI`), not the backend. |

None of the backend/frontend/exporter probes use HTTP health-check paths —
Penpot's backend/exporter don't expose a documented one
([penpot/penpot#4465](https://github.com/penpot/penpot/issues/4465)), so
those use `tcpSocket` probes instead. The frontend probes `GET /`, which
nginx always answers.

## Images

Pinned, verified-pullable tags as of writing:

- `docker.io/penpotapp/{backend,frontend,exporter}:2.17.2`
- `postgres:16-alpine`, `valkey/valkey:8-alpine`
- `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z.hotfix.7aa24e772` and
  `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z-cpuv1` — **not**
  `docker.io/minio/minio`: MinIO stopped publishing free images to Docker
  Hub in October 2025, so this chart uses their Quay.io mirror instead.

Bump `image.penpotTag` to track new Penpot releases; check
https://hub.docker.com/r/penpotapp/backend/tags for available tags first.

## OpenShift-specific notes

- Runs fine under the default `restricted-v2` SCC — no `anyuid` or other
  SCC grants needed. Postgres/Valkey/MinIO's official images create their
  data directories themselves at first run, so they end up owned by
  whatever arbitrary UID OpenShift assigns the pod; they don't require a
  fixed named UID the way some container images do.
- Exposure is via an OpenShift `Route` (`route.openshift.io/v1`), not a
  Kubernetes `Ingress` — set `route.enabled: false` if you front this with
  something else.

## Known dev-cluster caveat: BestEffort QoS

On a memory-constrained node (e.g. a default-sized OpenShift Local / CRC
VM shared with other operators/apps), see
`envirenment-penpot/values-dev.yaml` — it clears every component's
`resources` (both `requests` *and* `limits`; setting only `limits` doesn't
help, since the API server auto-fills a missing `requests` to match a
given `limits`) so pods become BestEffort and can still be scheduled. This
trades away scheduling/eviction guarantees; on a cluster with real
headroom, drop that override and let this chart's defaults apply.
