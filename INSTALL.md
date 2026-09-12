# Installing Penpot on OpenShift Local via Helm + ArgoCD

Walkthrough of how this was actually installed, in order, including the
two real problems hit along the way and how they were fixed. Lives in
this repo (rather than staying local-only) so the install is documented
in git, same as the chart itself.

## What Penpot needs

Penpot itself is 3 services (backend, frontend, exporter). Postgres
(data) and MinIO (asset storage) are both needed too — but there's a
third piece easy to miss: **Valkey/Redis**, which is required, not
optional. Penpot uses it for websocket/pub-sub coordination between
backend instances, even with a single replica.

| Piece | Role | Required? |
|---|---|---|
| PostgreSQL | primary datastore (files, teams, users, ...) | yes |
| Valkey (Redis-compatible) | websocket/pub-sub coordination, short-lived state | **yes** |
| MinIO (S3-compatible) | object storage for uploaded assets/exports | yes, if using the S3 backend (this install does); Penpot can alternatively use plain filesystem storage |
| SMTP server | sending invitation/verification emails | no — this dev install disables email verification and logs invite tokens to the backend pod's stdout instead |

See this repo's [README](README.md) for the full component table and the
env-var reference the chart is built against; see
[`envirenment-penpot`](https://github.com/dragos1993/envirenment-penpot)
and [`argocd-repo`](https://github.com/dragos1993/argocd-repo) for the
other two pieces.

## CRC vs. enterprise OpenShift — what's specific to this cluster

Since this was installed against OpenShift **Local** (CRC), not an
enterprise/multi-node cluster, it's worth being explicit about which
choices below are genuinely CRC-specific workarounds vs. things that
would apply anywhere on OpenShift (including a real cluster):

**CRC-specific (would likely not be needed on a properly-sized cluster):**
- Growing the CRC VM's memory allocation from its ~10.7Gi default to
  12Gi (`crc config set memory 12288`) — see step 6. Turned out to be
  the real fix: a completely empty, fresh CRC VM already has ~96% of
  memory *requested* by OpenShift's own core components alone, before
  any workload is added. This isn't about Penpot specifically or about
  other apps cluttering the cluster (that was the original, incomplete
  theory) — it's this default VM sizing being too small to leave
  meaningful headroom, period.
- Clearing `resources` (both `requests` and `limits`) entirely on every
  Penpot component in `envirenment-penpot/values-dev.yaml`. Still in
  place even after the memory increase (12Gi has *some* spare room, but
  not a lot) — see step 3. On a cluster with real spare memory, delete
  that override and let `release-penpot/values.yaml`'s normal
  (BestEffort → Burstable) requests/limits apply instead.
- The recurring `kube-apiserver`/`etcd` restarts and transient "TLS
  handshake timeout" / "Unauthorized" / "connection reset by peer"
  errors hit repeatedly during the first install attempt (see step 3):
  a direct symptom of the tight default memory margin, resolved by the
  memory increase in step 6 — after that, a full reinstall came up
  clean with zero pod restarts and no API server instability.

**Not CRC-specific — general OpenShift behavior (applies to any
cluster, enterprise included):**
- Running Postgres/Valkey/MinIO under the `restricted-v2` SCC with no
  `anyuid` grant (arbitrary UID assignment).
- The MinIO bucket-creation Job needing `HOME=/tmp` (arbitrary UID has
  no `/etc/passwd` entry, so `$HOME` defaults to `/`, which isn't
  writable) — `release-penpot/templates/minio.yaml`.
- Using an OpenShift `Route` instead of a Kubernetes `Ingress`.

**Specific to how ArgoCD happens to be installed on *this* cluster**
(via the community Argo CD Operator — this is a property of that
operator's default install, not of CRC, and wouldn't apply if this were
the OpenShift GitOps operator instead):
- Its `in-cluster` registration only manages the `argocd` namespace by
  default, so `penpot-app` initially failed with `namespace "penpot"
  ... is not managed` until the `penpot` namespace was labeled
  `argocd.argoproj.io/managed-by=argocd` — see `argocd-repo/README.md`.
- ArgoCD's `argocd-server` pod (the UI/API component) was already
  intermittently crash-looping *before* this install touched anything —
  visible in its own pod events going back to its creation. The sync
  engine (`argocd-application-controller`) is a separate, more stable
  component and kept working through that.

## 0. Starting point

- Cluster: OpenShift Local (CRC), `oc whoami` → `kubeadmin`,
  `cluster-admin` available.
- `helm` wasn't installed on this machine — installed the v3.16.4 binary
  to `~/.local/bin/helm` (no `sudo` available; downloaded from
  `get.helm.sh`, no package manager needed).
- ArgoCD was **already running** on this cluster — installed via the
  community **Argo CD Operator** (`argocd-operator`, `community-operators`
  catalog, `alpha` channel), in namespace `openshift-operators`, with an
  `ArgoCD` custom resource named `argocd` in namespace `argocd`. So there
  was no need to install the OpenShift GitOps operator from scratch here.

## 1. Reaching ArgoCD

```bash
oc get route argocd-server -n argocd
# https://argocd-server-argocd.apps-crc.testing
```

Open that URL in a browser (this machine already resolves
`*.apps-crc.testing` to `127.0.0.1` via `/etc/hosts`, kept in sync by a
CRC helper). Login is `admin` with the password from:

```bash
oc get secret argocd-cluster -n argocd -o jsonpath='{.data.admin\.password}' | base64 -d
```

(Run that yourself — it prints a real credential, so it's deliberately
not reproduced here.)

Or from the CLI, once you have the ArgoCD CLI installed:

```bash
argocd login argocd-server-argocd.apps-crc.testing --insecure
argocd app list
argocd app get penpot-app
```

Note: `argocd-server` on this cluster crash-loops intermittently (see
the callout above) — if the route/UI is briefly unreachable, that's why;
it self-recovers, and it doesn't affect whether ArgoCD is actually
syncing your app.

## 2. Namespace + secret (manual, out-of-band)

Nothing here is git-tracked or Helm/ArgoCD-managed — see this repo's
[README](README.md) for why.

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

## 3. The chart, and a memory surprise

Built this chart from scratch (Postgres, Valkey, MinIO + a
bucket-creation Job, backend, frontend, exporter, an OpenShift `Route`)
— see the [README](README.md) for the full component table and the
env-var reference it's built against (verified live against Penpot's
current docs/source: `PENPOT_OBJECTS_STORAGE_S3_*`, not the older
`PENPOT_ASSETS_STORAGE_*` names; Penpot 2.17.2).

First `helm install` attempt: every Penpot pod stuck `Pending`. This CRC
node's default memory allocation (~10Gi allocatable) was already ~99%
committed by *other* things already running here — ArgoCD, Tekton
Pipelines, a sample `app1` — before Penpot even entered the picture.

Two ways to fix that: grow the CRC VM's memory (stop/reconfigure/restart
the cluster), or shrink Penpot's own requests to fit. Chose the second
(no cluster restart, nothing else disrupted). That override lives in
`envirenment-penpot/values-dev.yaml` — see it and this repo's
[README](README.md)'s "Known dev-cluster caveat" section for the
mechanics (short version: a `limits` without a matching `requests` gets
`requests` auto-filled to match by the API server, so you have to clear
*both* to actually get BestEffort scheduling).

With BestEffort pods now competing for whatever real memory the node has
spare, the node's control plane itself (`kube-apiserver`, `etcd`) went
through several rounds of restarts and multi-minute stretches of
`net/http: TLS handshake timeout` / `connection reset by peer` /
`Unauthorized` errors from `oc` during this install — always
self-recovering within 1-3 minutes. One Penpot pod (`backend`) and
ArgoCD's own `argocd-server` were also killed/restarted by their
liveness probes during those windows, and likewise came back on their
own once the node stabilized. If this keeps recurring in normal use
(not just during a bulk install), growing the CRC VM's memory allocation
is the real fix — this workaround only makes the *scheduling* problem go
away, not the underlying tight memory margin.

## 4. A MinIO bucket-creation bug (OpenShift arbitrary UID)

The post-install Job that runs `mc mb` to create Penpot's assets bucket
initially failed in a crash loop:

```
mc: <ERROR> Unable to save new mc config. mkdir /.mc: permission denied.
```

Cause: under OpenShift's arbitrary-UID `restricted-v2` SCC, the
container's runtime UID has no matching `/etc/passwd` entry, so `$HOME`
resolves to `/` — not writable. Fixed by setting `HOME=/tmp` on that Job
container (`templates/minio.yaml`). This is general OpenShift behavior,
not CRC-specific — would hit the same way on any OpenShift cluster.

## 5. Install

Directly with Helm (what was actually run here first, to validate the
chart before pushing it through GitOps):

```bash
helm install penpot . -n penpot -f ../envirenment-penpot/values-dev.yaml
```

Then wired into ArgoCD via `argocd-repo/apps/penpot-app.yaml`:

```bash
oc apply -f ../argocd-repo/apps/penpot-app.yaml -n argocd
oc get application penpot-app -n argocd -w
```

### A second bug: ArgoCD couldn't manage the `penpot` namespace at all

The Application sat at `sync=Unknown health=Missing` with:

```
Failed to load live state: namespace "penpot" for Route "penpot" is not managed
```

This ArgoCD instance's `in-cluster` registration (the
`argocd-default-cluster-config` Secret in namespace `argocd`) only
allowed managing the `argocd` namespace itself, regardless of the
`default` AppProject's wildcard destinations. Fixed by labeling the
target namespace, which the Argo CD Operator watches for and uses to
update that Secret automatically:

```bash
oc label namespace penpot argocd.argoproj.io/managed-by=argocd
```

This is specific to the community Argo CD Operator's default
cluster-scope behavior, not to CRC — the OpenShift GitOps operator
manages cluster-wide by default and wouldn't need this step.

### A third bug: Deployment selectors didn't match between Helm CLI and ArgoCD

After the namespace fix, sync still failed on every Deployment:

```
Deployment.apps "penpot-backend" is invalid: spec.selector: Invalid
value: {...,"app.kubernetes.io/instance":"penpot-app",...}: field is
immutable
```

Cause: the chart's selector labels include
`app.kubernetes.io/instance: {{ .Release.Name }}`. The direct `helm
install` above used release name `penpot`; ArgoCD defaults the Helm
release name to the *Application's* name, `penpot-app` — a different
value, and `spec.selector` on a Deployment can't be patched in place
once set. Fixed by pinning the release name explicitly in
`argocd-repo/apps/penpot-app.yaml`:

```yaml
sources:
  - repoURL: https://github.com/dragos1993/release-penpot.git
    helm:
      releaseName: penpot   # must match the CLI install's release name
```

This is a general Helm/ArgoCD interaction, not CRC- or
OpenShift-specific — it would bite on any cluster if a chart's selector
labels are derived from `.Release.Name` and the CLI and GitOps paths use
different release names.

## 6. The real fix: the memory workaround wasn't enough on its own

Even after both ArgoCD bugs above were fixed and `penpot-app` briefly
reached `Synced`/`Healthy`, the node kept sliding back into distress:
`kube-apiserver`/`etcd` restarts, multi-minute stretches of `oc`
returning `TLS handshake timeout` / `connection reset by peer` /
`Unauthorized`, and the `penpot-backend` and `argocd-server` pods being
killed by their own liveness probes during those windows — each episode
longer than the last. The BestEffort workaround in step 3 fixed
*scheduling*, but it didn't fix the underlying problem: this CRC VM's
default ~10.7Gi memory allocation left the node with essentially **no**
real spare memory once its own core components (`kube-apiserver`,
`etcd`, monitoring, OLM, image registry, ingress, DNS, ...) were
running — confirmed by checking a completely fresh, empty CRC VM
(no Penpot, no ArgoCD, nothing) and finding it already had **96% of
memory requested** by OpenShift itself, before any workload was added.

The actual fix: stop CRC, grow its memory allocation, start it again.
The host here only has 15Gi total RAM, so there wasn't room for a huge
jump — 12Gi (up from the ~10.7Gi default) was the realistic ceiling,
leaving a few Gi for the host OS itself:

```bash
crc stop
crc config set memory 12288
crc start
```

That took allocatable memory from ~9.99Gi to ~11.5Gi and baseline
requests from 96% down to 82% — not a huge percentage change, but it was
the difference between "no headroom, node destabilizes under any load"
and "small-but-real headroom, everything schedules and stays up." After
this, a full clean reinstall (fresh `argocd-operator` install, `penpot`
namespace + secret, `penpot-app` applied) came up straight to
`Synced`/`Healthy` with all 6 pods `1/1 Running` and zero restarts — no
crash loops, no API server instability.

**This is the one CRC-specific fix in this whole document that isn't
really about Penpot at all** — it's about this default CRC VM sizing
being too small to comfortably run a second nontrivial app (or, as it
turned out, sometimes even to run *only* itself) on a 15Gi host. If your
host has more RAM to spare, give CRC more than 12Gi — the more headroom,
the less likely this recurs.

## 7. Verify

```bash
oc get pods -n penpot
oc get route penpot -n penpot
oc get application penpot-app -n argocd   # expect: Synced / Healthy
curl -skI https://penpot.apps-crc.testing/ | head -1   # expect: HTTP/1.1 200 OK (or 2xx)
```

Then open `https://penpot.apps-crc.testing` in a browser and create an
account — registration and password login are enabled, email
verification is disabled (see `values.yaml`'s `flags`), so signup works
without a real mailbox.

## Repo map

- [`release-penpot`](https://github.com/dragos1993/release-penpot) — the
  Helm chart (this repo).
- [`envirenment-penpot`](https://github.com/dragos1993/envirenment-penpot)
  — environment values (`values-dev.yaml` for this CRC cluster).
- [`argocd-repo`](https://github.com/dragos1993/argocd-repo) — the ArgoCD
  `Application` (`apps/penpot-app.yaml`) tying the two together.
