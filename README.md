# DBA Toolbox

This image provides a long-running Kubernetes toolbox pod with PostgreSQL and
MinIO clients preconfigured from a Kubernetes Secret.

The Kubernetes workload is a `StatefulSet` with a `volumeClaimTemplates` entry.
Kubernetes dynamically provisions the `/work` volume through the
`rook-cephfs` storage class.

## Included Tools

- `bash`
- `mc` / `mcli`, the MinIO client
- `psql`, `pg_dump`, and other PostgreSQL client tools
- `tar`, `gzip`, `coreutils`, and timezone data

Azure CLI is intentionally not included.

## Kubernetes Resources

The rendered manifests include:

- `Secret/dba-toolbox-connections`
- `StatefulSet/dba-toolbox`

The StatefulSet creates one PVC from this claim template:

```yaml
volumeClaimTemplates:
  - metadata:
      name: toolbox-work
    spec:
      accessModes:
        - ReadWriteMany
      storageClassName: rook-cephfs
      resources:
        requests:
          storage: 100Gi
```

For pod `dba-toolbox-0`, Kubernetes creates a PVC named:

```text
toolbox-work-dba-toolbox-0
```

## Connection Secret

Manage MinIO aliases and PostgreSQL services through
`k8s/secret.yaml`.

The entrypoint supports any number of connections using indexed environment
variables:

```text
MINIO_0_*
MINIO_1_*
MINIO_2_*

POSTGRES_0_*
POSTGRES_1_*
POSTGRES_2_*
```

You can either set `MINIO_COUNT` / `POSTGRES_COUNT`, or omit the counts and let
the entrypoint discover configured indexes from the environment.

### MinIO Variables

Required per MinIO instance:

```text
MINIO_<N>_ALIAS
MINIO_<N>_ENDPOINT
MINIO_<N>_ACCESS_KEY
MINIO_<N>_SECRET_KEY
```

Optional per MinIO instance:

```text
MINIO_<N>_API   # defaults to S3v4
MINIO_<N>_PATH  # defaults to auto
```

Example:

```yaml
stringData:
  MINIO_COUNT: "2"

  MINIO_0_ALIAS: minio-a
  MINIO_0_ENDPOINT: http://minio-a:9000
  MINIO_0_ACCESS_KEY: CHANGE_ME
  MINIO_0_SECRET_KEY: CHANGE_ME
  MINIO_0_API: S3v4
  MINIO_0_PATH: auto

  MINIO_1_ALIAS: minio-b
  MINIO_1_ENDPOINT: http://minio-b:9000
  MINIO_1_ACCESS_KEY: CHANGE_ME
  MINIO_1_SECRET_KEY: CHANGE_ME
```

At startup, the container runs `mc alias set` for each configured instance.

Use the aliases inside the pod:

```sh
mc ls minio-a
mc cp ./dump.sql minio-b/backups/dump.sql
```

### PostgreSQL Variables

Required per PostgreSQL connection:

```text
POSTGRES_<N>_SERVICE
POSTGRES_<N>_HOST
POSTGRES_<N>_DATABASE
POSTGRES_<N>_USER
POSTGRES_<N>_PASSWORD
```

Optional per PostgreSQL connection:

```text
POSTGRES_<N>_PORT     # defaults to 5432
POSTGRES_<N>_SSLMODE  # omitted unless set
```

Example:

```yaml
stringData:
  POSTGRES_COUNT: "2"

  POSTGRES_0_SERVICE: app
  POSTGRES_0_HOST: postgres-app
  POSTGRES_0_PORT: "5432"
  POSTGRES_0_DATABASE: app
  POSTGRES_0_USER: postgres
  POSTGRES_0_PASSWORD: CHANGE_ME

  POSTGRES_1_SERVICE: analytics
  POSTGRES_1_HOST: postgres-analytics
  POSTGRES_1_PORT: "5432"
  POSTGRES_1_DATABASE: analytics
  POSTGRES_1_USER: postgres
  POSTGRES_1_PASSWORD: CHANGE_ME
```

At startup, the container writes:

- `/home/backup/.pg_service.conf`
- `/home/backup/.pgpass`

Use the services inside the pod:

```sh
psql service=app
pg_dump service=analytics --format=custom --file=/work/analytics.dump
```

## Deploy

The Helm chart is the recommended deployment method:

```sh
helm upgrade --install dba-toolbox helm-charts/dba-toolbox \
  --namespace dba-toolbox --create-namespace \
  --set image.repository=registry.example.com/backup-tools \
  --set image.tag=latest
```

Set connection credentials in a private values file, or map individual
connections to native Kubernetes Secrets. The chart creates two separate
claims by default:

- `toolbox-work-<pod>` is the work workspace and can be replaced or resized.
- `toolbox-config-<pod>` stores MinIO aliases, S3 bucket mappings, and
  PostgreSQL client files. Both claims are StatefulSet volume-claim templates,
  and the StatefulSet retention policy keeps them when the workload is deleted
  or scaled down.

The configuration Secret remains the source of truth. On every startup the
entrypoint reconciles managed aliases and atomically regenerates PostgreSQL
files, so edits to the Secret take effect without leaving removed connections
behind. S3 bucket mappings are written to `/config/home/.s3-buckets` as
`alias=bucket` entries.

To resize the work workspace, resize the generated PVC directly after
confirming that the StorageClass allows expansion:

```sh
kubectl get storageclass rook-cephfs \
  -o jsonpath='{.allowVolumeExpansion}{"\\n"}'
kubectl patch pvc toolbox-work-dba-toolbox-0 \
  -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
```

The chart also keeps the existing manifests available for compatibility:

Render the manifests:

```sh
kubectl kustomize k8s
```

Apply them:

```sh
kubectl apply -k k8s
```

Open a shell in the toolbox:

```sh
kubectl exec -it statefulset/dba-toolbox -- bash
```

### Connection setup with native Kubernetes Secrets

The chart supports two connection modes:

1. Define connection values directly. The chart creates
   `<release>-connections`.
2. Set `existingSecret.name` on a connection and map its fields to a native
   Secret deployed through `extraObjects`.

Connections are maps, not lists. The map key is the default MinIO alias or
PostgreSQL service name. Keys are sorted before the chart assigns the internal
numeric environment indexes, so the entrypoint remains compatible with the
existing `MINIO_<N>_*` and `POSTGRES_<N>_*` variables. An explicit `alias` or
`service` field can override the map key when needed.

The second mode is useful when connection Secrets are managed as Kubernetes
manifests by a separate process. Set the chart values like this:

```yaml
connections:
  minio:
    primary-s3:
      api: S3v4
      path: auto
      existingSecret:
        name: s3-credentials
        endpointKey: endpoint
        accessKeyKey: accessKey
        secretKeyKey: secretKey
        bucketKey: bucket
  postgres:
    app:
      existingSecret:
        name: app-postgres-credentials
        userKey: username
        passwordKey: password
        databaseKey: database
        connectingStringKey: connectionString

extraObjects:
  - apiVersion: v1
    kind: Secret
    metadata:
      name: s3-credentials
    type: Opaque
    stringData:
      endpoint: https://s3.example.com
      accessKey: replace-me
      secretKey: replace-me
      bucket: database-backups
  - apiVersion: v1
    kind: Secret
    metadata:
      name: app-postgres-credentials
    type: Opaque
    stringData:
      username: backup
      password: replace-me
      database: app
      connectionString: postgresql://backup:replace-me@postgres-app:5432/app?sslmode=require
```

Deploy it with:

```sh
helm upgrade --install dba-toolbox helm-charts/dba-toolbox \
  --namespace dba-toolbox --create-namespace \
  --values connections-values.yaml
```

The chart still creates one generated Secret containing the indexed connection
environment variables. Per-connection `existingSecret` mappings override the
selected generated values with `secretKeyRef` values. The `name` must refer to
the Secret created in `extraObjects` (or to a Secret already present in the
namespace).

An empty `existingSecret` object, or an object with an empty `name`, disables
Secret-backed mapping for that connection and uses its regular values instead.
When a Secret name is set, the default S3 keys are `endpoint`, `accessKey`,
`secretKey`, and `bucket`; override them only when the Secret uses different
names. The default PostgreSQL keys are `username`, `password`, and `database`.

S3-compatible connection values are:

```text
MINIO_<N>_ALIAS       required; the name used by `mc`
MINIO_<N>_ENDPOINT    required; S3-compatible endpoint
MINIO_<N>_ACCESS_KEY  required
MINIO_<N>_SECRET_KEY  required
MINIO_<N>_API         optional; defaults to S3v4
MINIO_<N>_PATH        optional; defaults to auto
MINIO_<N>_BUCKET      optional; persisted as alias=bucket
```

For native Secret-backed S3 values, use this structure inside the connection:

```yaml
existingSecret:
  name: s3-credentials
  endpointKey: endpoint
  accessKeyKey: accessKey
  secretKeyKey: secretKey
  bucketKey: bucket
```

The key fields are optional when those defaults match the Secret. This is
equivalent to the shorter form:

```yaml
existingSecret:
  name: s3-credentials
```

Use an S3 connection inside the pod as `mc ls primary-s3` or
`mc cp file.dump primary-s3/database-backups/`. Bucket mappings are also
persisted in `/config/home/.s3-buckets` for automation that needs the default
bucket associated with each alias.

PostgreSQL connection values are:

```text
POSTGRES_<N>_SERVICE    required; value used by `psql service=...`
POSTGRES_<N>_HOST       required
POSTGRES_<N>_PORT       optional; defaults to 5432
POSTGRES_<N>_DATABASE    required
POSTGRES_<N>_USER       required
POSTGRES_<N>_PASSWORD   required
POSTGRES_<N>_SSLMODE    optional
```

For native Secret-backed PostgreSQL values, use this structure:

```yaml
existingSecret:
  name: some-k8s-secret
  passwordKey: password
  userKey: username
  databaseKey: database
  connectingStringKey: connectionString
```

For the normal host/database/user/password form, only the `name` is needed
when the Secret uses the default keys:

```yaml
existingSecret:
  name: app-postgres-credentials
```

`connectingStringKey` is optional. When present, the referenced value is used
as the PostgreSQL service connection string and host/database/user/password do
not need to be supplied in Helm values. Otherwise, map the individual fields.

The entrypoint generates `/config/home/.pg_service.conf` and
`/config/home/.pgpass`. Use the configured service names with
`psql service=app` or `pg_dump service=analytics --format=custom
--file=/work/analytics.dump`.

For production, avoid committing credentials in a values file. If a Secret is
created outside Helm, use the same `existingSecret` mapping without adding it
to `extraObjects`. If it is managed with the chart, protect the values file and
use `stringData` or encrypted-secrets tooling. A change to chart-managed
`extraObjects` or generated connection values rolls the pod automatically; for
an externally modified Secret, run `kubectl rollout restart statefulset/dba-toolbox`.

### External Secrets Operator

External Secrets Operator can hydrate the native target Secrets used by the
chart. The operator and its `SecretStore` or `ClusterSecretStore` must already
be installed. Add `ExternalSecret` resources to `extraObjects`, and set each
connection's `existingSecret.name` to the target Secret name:

```yaml
connections:
  minio:
    primary-s3:
      existingSecret:
        name: dba-toolbox-s3
        endpointKey: endpoint
        accessKeyKey: accessKey
        secretKeyKey: secretKey
        bucketKey: bucket
  postgres:
    app:
      existingSecret:
        name: dba-toolbox-postgres
        userKey: username
        passwordKey: password
        databaseKey: database
        connectingStringKey: connectionString

extraObjects:
  - apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: dba-toolbox-s3
    spec:
      refreshInterval: 1h
      secretStoreRef:
        name: production-store
        kind: ClusterSecretStore
      target:
        name: dba-toolbox-s3
        creationPolicy: Owner
      data:
        - secretKey: endpoint
          remoteRef:
            key: production/backup/s3/endpoint
        - secretKey: accessKey
          remoteRef:
            key: production/backup/s3/access-key
        - secretKey: secretKey
          remoteRef:
            key: production/backup/s3/secret-key
        - secretKey: bucket
          remoteRef:
            key: production/backup/s3/bucket

  - apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: dba-toolbox-postgres
    spec:
      refreshInterval: 1h
      secretStoreRef:
        name: production-store
        kind: ClusterSecretStore
      target:
        name: dba-toolbox-postgres
        creationPolicy: Owner
      data:
        - secretKey: username
          remoteRef:
            key: production/backup/postgres/username
        - secretKey: password
          remoteRef:
            key: production/backup/postgres/password
        - secretKey: database
          remoteRef:
            key: production/backup/postgres/database
        - secretKey: connectionString
          remoteRef:
            key: production/backup/postgres/connection-string
```

Use `apiVersion: external-secrets.io/v1beta1` instead if that is the API
version installed by the External Secrets Operator in your cluster. The
operator creates `dba-toolbox-s3` and `dba-toolbox-postgres`; the chart then
reads those native Secrets using `secretKeyRef`. If an ExternalSecret refresh
changes credentials, restart the StatefulSet to force the entrypoint to
reconcile the persisted aliases and PostgreSQL files:

```sh
kubectl rollout restart statefulset/dba-toolbox -n dba-toolbox
```

### Chart releases and CI

CI runs for bare SemVer tags only, for example `0.0.3` or `1.2.3`. Tags with a
leading `v`, such as `v1.2.3`, do not trigger the release workflow.

Before creating a release tag, update both `version` and `appVersion` in
`helm-charts/dba-toolbox/Chart.yaml` to the exact tag value:

```yaml
version: 0.0.3
appVersion: "0.0.3"
```

The workflow verifies this 1:1 match, builds and publishes the image, packages
the chart, and publishes it to the GHCR OCI repository:

```text
oci://ghcr.io/<owner>/helm-charts/dba-toolbox
```

The CI flow is:

```text
validate chart and shell
        ↓
build one local quarantine image
        ↓
Trivy source and image scans
        ↓
promote the exact scanned image digest to release tags
        ↓
sign the published image
        ├── prune old image artifacts
        └── publish the Helm chart for SemVer tags
```

Pull requests run validation and scans but do not publish. Branch pushes to
`main` publish the image and run cleanup. Bare SemVer tag pushes additionally
publish the matching Helm chart. The image is built only once; publishing
retags and pushes the local image that already passed the Trivy scan.

Install a published chart with:

```sh
helm upgrade --install dba-toolbox \
  oci://ghcr.io/<owner>/helm-charts/dba-toolbox \
  --version 0.0.3 \
  --namespace dba-toolbox --create-namespace \
  --values connections-values.yaml
```

## Entrypoint Behavior

The entrypoint:

1. Configures all MinIO aliases from the Secret.
2. Reconciles S3 bucket mappings from the Secret.
3. Writes PostgreSQL service and password files from the Secret.
4. Keeps the container running with `sleep infinity`.

The Helm defaults use a non-root UID/GID, RuntimeDefault seccomp, no privilege
escalation, all capabilities dropped, a read-only root filesystem, and default
CPU/memory requests and limits suitable for the Kubernetes Restricted Pod
Security Admission profile.

If any indexed connection is missing a required variable, startup fails and the
missing key is logged.
