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

- **PostgreSQL** — Penpot's primary datastore. **Has a PVC** (`penpot-postgres`).
- **Valkey** (Redis-compatible) — required, not optional. Penpot uses it for
  websocket/pub-sub coordination between backend instances and short-lived
  data, even with a single backend replica. **No PVC** — it's an ephemeral
  cache/pub-sub broker, not a store of record, so there's nothing worth
  persisting across a restart.
- **MinIO** (S3-compatible) — object storage for uploaded assets (images,
  exports, etc). Penpot can also use plain filesystem storage
  (`PENPOT_OBJECTS_STORAGE_BACKEND=fs`), but this chart defaults to S3/MinIO.
  **Has a PVC** (`penpot-minio`).

So exactly **2 of the 6 components have persistent storage**: Postgres
and MinIO. Backend/frontend/exporter are stateless (all their state
lives in Postgres/MinIO/Valkey), and Valkey itself is disposable cache.

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
| `penpot-postgres` | Deployment + PVC | Single replica, `Recreate` strategy. Uses Red Hat's certified image (`registry.redhat.io/rhel9/postgresql-16`), which manages its own data subdirectory internally (no `PGDATA` override needed here, unlike the plain upstream `postgres` image). |
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

- `docker.io/penpotapp/{backend,frontend,exporter}:2.17.2` — Penpot is a
  third-party app; it has no equivalent anywhere in the OpenShift/Red Hat
  registry, only on Docker Hub.
- `registry.redhat.io/rhel9/postgresql-16:1` and
  `registry.redhat.io/rhel9/valkey-8:8` — Red Hat's certified images,
  pulled from the OpenShift/Red Hat registry rather than the plain
  upstream `postgres`/`valkey` Docker Hub images. Needs a Red Hat
  account's pull secret configured on the cluster (CRC already has one
  by default). **These use a different configuration interface than the
  upstream images** — see `templates/postgres.yaml`/`valkey.yaml`
  (`POSTGRESQL_USER`/`PASSWORD`/`DATABASE` env vars instead of
  `POSTGRES_*`, data at `/var/lib/pgsql/data` instead of
  `/var/lib/postgresql/data`) and INSTALL.md for a real incident this
  difference caused when switching.
- `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z.hotfix.7aa24e772` and
  `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z-cpuv1` — **not**
  `docker.io/minio/minio`: MinIO stopped publishing free images to Docker
  Hub in October 2025, so this chart uses their Quay.io mirror instead.
  MinIO has no equivalent in the OpenShift/Red Hat registry either — Red
  Hat doesn't ship MinIO as a certified product.

Bump `image.penpotTag` to track new Penpot releases; check
https://hub.docker.com/r/penpotapp/backend/tags for available tags first.
For Postgres/Valkey version bumps, check available tags with (needs the
cluster's Red Hat pull secret):
```bash
podman search --authfile=<path-to-pull-secret.json> --list-tags registry.redhat.io/rhel9/postgresql-16
```

## OpenShift-specific notes

- Runs fine under the default `restricted-v2` SCC — no `anyuid` or other
  SCC grants needed. Postgres/Valkey/MinIO's official images create their
  data directories themselves at first run, so they end up owned by
  whatever arbitrary UID OpenShift assigns the pod; they don't require a
  fixed named UID the way some container images do. This is true on any
  OpenShift cluster, CRC or enterprise — not a CRC-specific accommodation.
- Exposure is via an OpenShift `Route` (`route.openshift.io/v1`), not a
  Kubernetes `Ingress` — set `route.enabled: false` if you front this with
  something else. Also not CRC-specific.

## Configuration reference: CRC value vs. what a properly-sized/enterprise cluster would use

This chart was built and tuned against OpenShift **Local (CRC)**, a
single-node, deliberately small cluster. Below is every place a value
here reflects that, versus what the *same chart* would typically run
with on a real multi-node/enterprise OpenShift cluster. See
[INSTALL.md](INSTALL.md) for the full narrative of how each of these was
actually discovered (including the two problems that led to them).

### Resource requests/limits — the big one

`values.yaml`'s own defaults, below, are what this chart considers
"normal" — sized for a real cluster with actual spare capacity, not
tuned down for anything:

| Component | requests | limits |
|---|---|---|
| backend | 200m CPU / 512Mi mem | 1Gi mem |
| frontend | 100m CPU / 128Mi mem | 256Mi mem |
| exporter | 200m CPU / 256Mi mem | 512Mi mem |
| postgres | 100m CPU / 256Mi mem | 512Mi mem |
| valkey | 50m CPU / 64Mi mem | 128Mi mem |
| minio | 100m CPU / 256Mi mem | 512Mi mem |

That's ~750m CPU and ~1.4Gi memory requested in total — trivial for any
real cluster node, but on this project's default-sized CRC VM
(~10.7Gi allocatable), OpenShift's *own* core components alone
(`kube-apiserver`, `etcd`, monitoring, OLM, image registry, ingress,
DNS, ...) were already committing ~96% of that before Penpot entered
the picture at all (verified on a completely empty, fresh CRC VM — see
INSTALL.md step 6). There wasn't room left for these requests to be
admitted.

`envirenment-penpot/values-dev.yaml` is the CRC-specific override: it
sets every component's `resources` to `{}` (both `requests` *and*
`limits` cleared — setting only `limits` doesn't help, since the API
server auto-fills a missing `requests` to match a given `limits`),
making every Penpot pod **BestEffort QoS**. That's what lets pods
schedule at all on this VM, at the cost of scheduling/eviction
guarantees — BestEffort pods are the first evicted under real memory
pressure and get no CPU-time guarantee, which is exactly what caused
the JVM backend's startup-time blowups documented in INSTALL.md's probe
section. **On a properly-sized or enterprise cluster, this override
should not exist at all** — delete `values-dev.yaml`'s `resources`
blocks (or don't create an override file in the first place) and let
this chart's own defaults above apply; they give real Burstable-tier
QoS.

### Storage class

`postgresql.storageClassName` / `minio.storageClassName` default to
`""` (empty), meaning "use whatever the cluster's default
StorageClass is" — this is deliberately cluster-agnostic, not a CRC
value. What differs is *what that default StorageClass actually is*:

| | CRC | Typical enterprise cluster |
|---|---|---|
| Name (example) | `crc-csi-hostpath-provisioner` | e.g. `gp3-csi` (AWS EBS), `ocs-storagecluster-ceph-rbd` (ODF/Ceph), `managed-premium` (Azure Disk) |
| Backing | A directory on the CRC VM's single local disk | Network-attached block storage |
| Reclaim policy | `Retain` | Commonly `Delete` |
| Multi-node reschedule | N/A (one node) | Works — volume follows the pod to another node |

The `Retain` + local-disk combination is why deleting a PVC (or the
whole namespace) on CRC leaves an orphaned, intact `Released`
PersistentVolume behind rather than freeing the disk immediately, and
why a fresh install after that gets a **new, empty** volume instead of
reusing the old one — see the "does my data survive" walkthrough in
this project's history. On an enterprise cluster with `Delete` reclaim
policy, deleting a PVC actually frees the backing storage right away.

### Route TLS

`route.tlsTermination: edge` isn't CRC-specific — `edge` termination is
a normal, common choice on any OpenShift cluster. What *is*
environment-specific is where the certificate comes from: CRC's
`apps-crc.testing` wildcard route uses a self-signed default certificate
(hence needing `curl -k` / accepting a browser warning in this project's
docs), whereas an enterprise cluster's default router certificate is
typically a real one (corporate CA or a public CA via cert-manager),
so no browser warning and no `-k` needed.

### Images

Pinned versions and the Quay.io MinIO mirror (instead of
`docker.io/minio/minio`, which stopped publishing free images in
October 2025) apply everywhere this chart is deployed — not CRC-specific.
Pulling Postgres/Valkey from `registry.redhat.io` also isn't CRC-specific
per se (any OpenShift cluster can do it), but it does require a Red Hat
account's pull secret to be present on the cluster — CRC bundles one
automatically, but a from-scratch/bare-metal OpenShift install might not
have one configured yet (`oc get secret pull-secret -n openshift-config`
to check).

### Probe timing

Covered in full in [INSTALL.md](INSTALL.md#probe-configuration-and-why)
— short version: the values in `templates/*.yaml` themselves are
general-purpose and not CRC-specific, but this project directly observed
them being pushed past their tolerance *because of* the BestEffort
override above (CPU-starved JVM startup taking minutes instead of
seconds). On a cluster where Penpot's pods get their requested CPU
share guaranteed (i.e., not BestEffort), the documented timings hold up
as designed.

## Verifying it's all actually wired up

"All pods `Running`" doesn't by itself prove the backend can reach
Postgres/Valkey/MinIO — the `tcpSocket` probes explained above can't
tell you that (see the probe section's "real, observed gap" example).
Here's how to actually check each connection.

### Pods and storage

```bash
oc get pods -n penpot
```

All 6 should be `1/1 Running`: `penpot-backend`, `penpot-frontend`,
`penpot-exporter`, `penpot-postgres`, `penpot-valkey`, `penpot-minio`.

```bash
oc get pvc -n penpot
```

Expect **exactly 2** PersistentVolumeClaims: `penpot-postgres` and
`penpot-minio`. Valkey has none — it's an ephemeral cache/pub-sub
broker, not a store of record, so there's nothing there worth
persisting across a restart (see `templates/valkey.yaml`).

### Backend → Postgres and Valkey (log evidence)

The backend logs an explicit line for each connection it opens at
startup:

```bash
oc logs -n penpot deploy/penpot-backend | grep -E "initialize connection pool|initialize redis client|welcome to penpot"
```

Expect something like:

```
[...] app.db - hint="initialize connection pool", name="main", uri="postgresql://penpot-postgres:5432/penpot", ...
[...] app.redis - hint="initialize redis client", uri="redis://penpot-valkey:6379/0"
[...] app.main - hint="welcome to penpot", flags="...", worker?=true, version="2.17.2"
```

The `welcome to penpot` line only prints if startup (including running
Postgres migrations) succeeded end to end — if Postgres or Valkey were
unreachable, the process would be stuck retrying or crash before
reaching that line.

A second, functional proof: query Postgres directly for data the app
created (e.g. after registering a user in the UI):

```bash
oc exec -n penpot deploy/penpot-postgres -- psql -U penpot -d penpot -c \
  "SELECT id, email, fullname, is_active, created_at FROM profile;"
```

Rows showing up here means the whole path (browser → Route → frontend
→ backend → Postgres) worked.

### Backend/Exporter → Valkey (live connection count)

```bash
oc exec -n penpot deploy/penpot-valkey -- valkey-cli info clients
```

`connected_clients` should be ≥ 2 (backend and exporter both hold open
connections) whenever those pods are up.

### Backend → MinIO (bucket + object evidence)

The bucket-creation Job (`templates/minio.yaml`) already proves initial
S3 connectivity by creating the bucket — confirm it exists:

```bash
oc exec -n penpot deploy/penpot-minio -- ls -la /data
```

Expect a `penpot` directory alongside MinIO's own `.minio.sys`. Unlike
Postgres/Valkey, the backend doesn't log an explicit "connected to S3"
line at startup (the S3 client is lazily used per-request, not
connection-tested at boot), so the practical proof is functional:
upload an image or set a profile avatar in the Penpot UI, then check
that new objects appear:

```bash
oc exec -n penpot deploy/penpot-minio -- find /data/penpot -type f
```

If backend↔MinIO were broken, that upload would fail in the UI with an
error rather than silently succeeding.

### Route and end-to-end HTTP

```bash
oc get route penpot -n penpot
curl -sk https://penpot.apps-crc.testing/ -o /dev/null -w "HTTP %{http_code}\n"
curl -sk https://penpot.apps-crc.testing/ | grep -o "<title>[^<]*</title>"
```

Expect `HTTP 200` and `<title>Penpot | Full-stack design</title>` (or
similar) — confirms the frontend is serving real content through the
Route, not just that the pod is up.
