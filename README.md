# DBA Toolbox

This image provides a long-running Kubernetes toolbox pod with PostgreSQL and
MinIO clients preconfigured from a Kubernetes Secret.

The Kubernetes workload is a `StatefulSet` with a `volumeClaimTemplates` entry.
Kubernetes dynamically provisions the `/backup` volume through the
`rook-cephfs` storage class.

## Included Tools

- `bash`
- `mc` / `mcli`, the MinIO client
- `psql`, `pg_dump`, and other PostgreSQL client tools
- `tar`, `gzip`, `coreutils`, and timezone data
- `update-ca-certificates` for loading custom CA bundles at runtime

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
pg_dump service=analytics --format=custom --file=/backup/analytics.dump
```

## Deploy

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

## Custom CAs

The container runs as the non-root `backup` user. The image grants that user
write access to Alpine's CA trust store so you can add certificates at runtime
without changing users.

Mount one or more PEM-encoded `.crt` files into:

```text
/usr/local/share/ca-certificates
```

Then refresh the trust store inside the pod:

```sh
update-ca-certificates
```

## Entrypoint Behavior

The entrypoint:

1. Configures all MinIO aliases from the Secret.
2. Writes PostgreSQL service and password files from the Secret.
3. Keeps the container running with `sleep infinity`.

If any indexed connection is missing a required variable, startup fails and the
missing key is logged.
