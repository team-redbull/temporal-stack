# temporal-stack

A self-contained Helm chart that deploys a **production-style Temporal cluster** on
OpenShift, with a bundled PostgreSQL and the Temporal Web UI. Everything lives in a
single namespace — no cluster-scoped resources.

## What it deploys

| Component   | Detail |
|-------------|--------|
| PostgreSQL  | Bitnami subchart (`postgresql`), persistent volume, SQL visibility store |
| Temporal    | Split services — `frontend`, `history`, `matching`, `worker` (2 replicas each) |
| Schema      | Post-install/upgrade hook Job: creates `temporal` + `temporal_visibility` DBs & schemas |
| Setup       | Post-install/upgrade hook Job: registers the `default` namespace + search attributes |
| Web UI      | `temporalio/ui` Deployment + Service + OpenShift **Route** (edge TLS) |

Service topology and the `cluster_membership`-table based ringpop discovery mean the
server pods find each other by pod IP — no headless service required.

## Prerequisites

- OpenShift 4.x (tested on 4.18) with a default `StorageClass`
- `helm` 3.8+ (OCI support) and `oc`
- Outbound pull access to `docker.io` and `quay.io`

## Install

```sh
helm dependency build .
oc new-project temporal
helm install temporal . -n temporal
```

Watch it come up:

```sh
oc get pods -n temporal -w
```

Open the UI:

```sh
oc get route temporal-ui -n temporal -o jsonpath='https://{.spec.host}{"\n"}'
```

Connect a Temporal client (in-cluster, gRPC):

```
temporal-frontend.temporal.svc.cluster.local:7233
```

## OpenShift specifics (why this chart "just works")

- **Arbitrary UID (restricted-v2 SCC):** no container pins `runAsUser`/`fsGroup`.
  An init container seeds the image's `/etc/temporal/config` into a writable
  `emptyDir` so the entrypoint can render its config.
- **PostgreSQL:** `global.compatibility.openshift.adaptSecurityContext: auto`
  strips the incompatible security context from the Bitnami subchart.
- **Probes** target each role's membership port — the `worker` service has no
  client gRPC listener, only membership.
- **Namespace/search-attribute provisioning** is done once by the setup Job
  (per-pod auto-setup provisioning is disabled), so it scales cleanly.

## Air-gapped install

In an air-gapped (offline) environment you must do three things: **mirror every
image** into your private Artifactory registry, **point the chart at those
images**, and (usually) **use an existing managed PostgreSQL** instead of the
bundled one. The PostgreSQL subchart is already vendored under `charts/`, so no
Helm OCI pull is needed at install time.

### 1. Pull, retag, and push the images to Artifactory

These are every image the chart pulls. From a workstation with internet access,
pull each one, retag it under your Artifactory Docker registry, and push:

| Source image | Used by |
|--------------|---------|
| `docker.io/temporalio/auto-setup:1.29.7` | server pods (frontend/history/matching/worker) + config init |
| `docker.io/temporalio/admin-tools:1.29.7-tctl-1.18.4-cli-1.7.2` | schema Job + namespace-setup Job |
| `docker.io/temporalio/ui:2.51.0` | Web UI |
| `docker.io/busybox:1.36` | wait-for init containers in the hook Jobs |
| `docker.io/bitnamilegacy/postgresql:17.6.0-debian-12-r4` | bundled PostgreSQL **(skip if using external DB)** |

```sh
# Your Artifactory Docker registry (virtual/local repo), e.g.:
ARTIFACTORY=artifactory.example.com/temporal-docker

docker login artifactory.example.com

for img in \
  temporalio/auto-setup:1.29.7 \
  temporalio/admin-tools:1.29.7-tctl-1.18.4-cli-1.7.2 \
  temporalio/ui:2.51.0 \
  busybox:1.36 \
  bitnamilegacy/postgresql:17.6.0-debian-12-r4 ; do
    docker pull docker.io/$img
    docker tag  docker.io/$img $ARTIFACTORY/$img
    docker push $ARTIFACTORY/$img
done
```

This preserves the original repository paths under your Artifactory repo, so the
final references look like
`artifactory.example.com/temporal-docker/temporalio/auto-setup:1.29.7`.

### 2. Point the chart at Artifactory

Create a values file, e.g. `values-airgapped.yaml`, overriding **only the image
fields** (everything else keeps its default):

```yaml
# Pull secret for Artifactory (create it in the temporal namespace first)
imagePullSecrets:
  - name: artifactory

# Temporal server (frontend/history/matching/worker + config init)
temporal:
  image:
    repository: artifactory.example.com/temporal-docker/temporalio/auto-setup
    tag: "1.29.7"
  # schema Job + namespace-setup Job
  schema:
    image:
      repository: artifactory.example.com/temporal-docker/temporalio/admin-tools
      tag: "1.29.7-tctl-1.18.4-cli-1.7.2"

# Web UI
ui:
  image:
    repository: artifactory.example.com/temporal-docker/temporalio/ui
    tag: "2.51.0"

# wait-for init containers (hook Jobs)
waitImage:
  repository: artifactory.example.com/temporal-docker/busybox
  tag: "1.36"
```

> The image `repository` is the **full path including registry host**; there is no
> separate `registry:` field for the Temporal/UI/wait images. (The bundled
> PostgreSQL subchart is the exception — see below — because it has its own
> `image.registry`.)

Create the pull secret once:

```sh
oc create secret docker-registry artifactory -n temporal \
  --docker-server=artifactory.example.com \
  --docker-username=<user> --docker-password=<token-or-api-key>
```

### 3a. Use an existing (hosted) PostgreSQL — recommended for air-gapped

Disable the bundled database and point Temporal at your managed instance. The
schema/namespace Jobs and all server pods read the password from a Secret you
create.

```yaml
postgresql:
  enabled: false          # do not deploy the bundled PostgreSQL

database:
  driver: postgres12      # works with PostgreSQL 12..17
  host: pg.internal.example.com   # your hosted PostgreSQL host
  port: 5432
  user: temporal_admin    # must be allowed to CREATE DATABASE (for schema setup)
  existingSecret: temporal-db      # Secret you create (see below)
  secretKey: password              # key in that Secret holding the password
  temporalDb: temporal
  visibilityDb: temporal_visibility
```

Create the password Secret the chart references:

```sh
oc create secret generic temporal-db -n temporal \
  --from-literal=password='<db-password>'
```

Notes for an external DB:
- The schema hook Job runs `create-database` for `temporal` and
  `temporal_visibility`, so the `database.user` needs `CREATEDB`. If your DBA
  pre-creates the two databases, the Job's create step is a harmless no-op.
- TLS: the Temporal `postgres12` plugin connects without TLS by default. If your
  hosted DB enforces TLS, that requires extra server config beyond these values —
  open an issue / extend the dynamic config template.

### 3b. Or keep the bundled PostgreSQL with a mirrored image

If you do want the in-cluster database, push the Bitnami image to Artifactory (it's
in the loop in step 1) and override its **own** `registry` + `repository` fields
(note this subchart uses a separate `registry:`):

```yaml
postgresql:
  enabled: true
  image:
    registry: artifactory.example.com
    repository: temporal-docker/bitnamilegacy/postgresql
    tag: 17.6.0-debian-12-r4
```

> Why `bitnamilegacy`? Docker Hub's `bitnami/postgresql` now only publishes
> `:latest`; concrete, reproducible tags moved to `bitnamilegacy`. Any
> PostgreSQL 12+ Bitnami image works if you prefer a different one.

### 4. Install offline

```sh
oc new-project temporal
helm install temporal . -n temporal -f values-airgapped.yaml
```

No external network calls are made: images come from Artifactory and the
PostgreSQL subchart is vendored in `charts/`.

## Secrets in production

The default `postgresql.auth.postgresPassword` in `values.yaml` is a **non-secret
placeholder** for the bundled-DB test path. For production:

- External DB → use `database.existingSecret` (section 3a); never put the password
  in values.
- Bundled DB → set `postgresql.auth.existingSecret` and remove the inline password.

## Common overrides

```yaml
# Larger DB volume on a specific StorageClass (bundled DB)
postgresql:
  primary:
    persistence:
      size: 50Gi
      storageClass: my-fast-rwo

# Scale a role
temporal:
  services:
    history:
      replicaCount: 4

# Pin the UI Route hostname / disable the Route
ui:
  route:
    host: temporal.apps.example.com   # empty => auto-assigned
    # enabled: false                  # ClusterIP only
```

## Uninstall

```sh
helm uninstall temporal -n temporal
oc delete pvc -n temporal --all   # PVCs are retained by default
```
