# `secrets/` — SealedSecrets only

**Never commit a plaintext `Secret`, `.env`, private key, htpasswd, or S3 key
here (or anywhere in this repo).** Only **SealedSecrets** — asymmetrically
encrypted by the cluster's Sealed Secrets controller — belong in Git. They are
safe to store publicly: only the in-cluster controller holds the private key.

## Workflow

1. Build a *plaintext* Secret **locally** (never commit it). Templates with
   placeholders live in `secrets/examples/` to show the required keys.
2. Seal it for the target namespace and write the result here:

   ```bash
   make seal-secret NS=app-dev IN=/tmp/app-back-app.yaml OUT=secrets/app-dev-app-back-app.yaml
   ```

   (`make seal-secret` runs `kubeseal --format yaml` against the controller.)
3. Commit only the sealed output. ArgoCD/​Helm reference the resulting Secret by
   name (see `chart/values.yaml: appSecretName`, and each platform values file).

## Secrets required (create one SealedSecret per item, in the namespace shown)

| Secret (Secret name) | Namespace(s) | Keys | Consumed by |
|---|---|---|---|
| `app-back-app`          | app-dev, app-prod | `APP_KEY`, `DB_USERNAME`, `DB_PASSWORD`, `BACKUP_DB_USER`, `BACKUP_DB_PASSWORD`, `REDIS_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `MAIL_*` | app chart (`envFrom`) |
| `registry-pull`      | app-dev, app-prod | `.dockerconfigjson` (type `kubernetes.io/dockerconfigjson`) | image pulls |
| `seaweedfs-s3-config`| seaweedfs | `config.json` (S3 identities) | SeaweedFS filer S3 |
| `seaweedfs-s3-admin` | seaweedfs | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | bucket-create Job |
| `registry-s3`        | registry  | `accessKey`, `secretKey` | registry S3 backend |
| `registry-htpasswd`  | registry  | `htpasswd` | registry auth |
| `mysql-auth`         | mysql     | `mysql-root-password`, `mysql-password`, `mysql-replication-password`, `BACKUP_DB_PASSWORD` | MySQL |
| `redis-auth`         | redis     | `redis-password` | Redis |
| `grafana-admin`      | monitoring| `admin-user`, `admin-password` | Grafana |

See `docs/USAGE.md` for exact generation commands (`openssl rand`, `php artisan
key:generate`, `htpasswd`, `kubectl create secret ... --dry-run | kubeseal`).
