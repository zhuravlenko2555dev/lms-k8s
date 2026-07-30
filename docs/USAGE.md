# lms-k8s — Usage & Setup Guide (Config repo)

This is the **§0.A** guide for the Config repo
(`git@github.com:zhuravlenko2555dev/lms-k8s.git`). The App repo is
`git@github.com:zhuravlenko2555dev/lms-laravel-back.git`. It covers what was
generated, **every credential** and where it goes, and how to run each workflow.
Companion: `INFRASTRUCTURE.md` (architecture/runbook), `SECURITY-REVIEW.md` (§0.B).

> All commands use **placeholders** — never commit real values. Secrets go into
> the cluster **only** as SealedSecrets (`secrets/`). Plaintext is `.gitignore`d.

---

## 1. What was generated and how it fits together

- **`chart/`** — the app: `web` (php-fpm + nginx sidecar serving the SPA and
  proxying `/api`,`/up`), `worker` (`queue:work`), `scheduler` (CronJob
  `schedule:run`), a **pre-upgrade `migrate --force` hook**, a **manual
  migrate-rollback Job**, a **backup CronJob**, a **restore Job**, Service,
  Ingress + Traefik middlewares, default-deny NetworkPolicies, per-workload
  ServiceAccounts, ServiceMonitor, HPA, PDB.
- **`envs/{dev,prod}/values.yaml`** — per-env overrides; `image.tag` is written by
  the App repo (CI for dev, promote-PR for prod).
- **`platform/`** + **`argocd/`** — ArgoCD app-of-apps that installs the whole
  platform by sync waves, and the per-env app ApplicationSet.
- **`secrets/`** — SealedSecrets only. **`Makefile`** — day-2 operations.

Flow: App CI builds+scans+pushes the image → bumps `envs/<env>/values.yaml` →
ArgoCD (watching **only this repo**) rolls it out. See `INFRASTRUCTURE.md`.

---

## 2. Prerequisites: private CA trust + `*.lms.local` DNS

Because the domain is **`.local`** with a **private CA**, every machine that
talks to the cluster (self-hosted runner, operators, browsers) must:

1. **Resolve `*.lms.local` → the Traefik LoadBalancer IP.** Options:
   - Local DNS (dnsmasq/CoreDNS/Pi-hole): wildcard `*.lms.local → <LB_IP>`.
   - Or `/etc/hosts` per host:
     ```
     <LB_IP>  app.lms.local dev.lms.local registry.lms.local grafana.lms.local argocd.lms.local
     ```
2. **Trust the private CA** (once cert-manager has minted it):
   ```bash
   # Export the CA cert (public part only) from the cluster:
   kubectl -n cert-manager get secret lms-local-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > lms-local-ca.crt
   # Linux runner:
   sudo cp lms-local-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
   # Docker daemon (to push to registry.lms.local):
   sudo mkdir -p /etc/docker/certs.d/registry.lms.local
   sudo cp lms-local-ca.crt /etc/docker/certs.d/registry.lms.local/ca.crt
   sudo systemctl restart docker
   ```
   Without this, `docker push`, `git`, and `argocd` calls fail TLS verification.

---

## 3. Every credential — how to create it, where it goes

Create each as a **local plaintext Secret**, then **seal** and commit only the
sealed file:

```bash
make seal-secret NS=<namespace> IN=/tmp/<secret>.yaml OUT=secrets/<ns>-<name>.yaml
rm /tmp/<secret>.yaml     # never commit the plaintext
```

| Credential | Namespace | Create it |
|---|---|---|
| **`APP_KEY`** (in `app-back-app`) | app-dev, app-prod | `php artisan key:generate --show` (or `echo base64:$(openssl rand -base64 32)`) |
| **DB app user/pass** (`DB_USERNAME`/`DB_PASSWORD` in `app-back-app`, and `mysql-auth`) | app-*, mysql | `openssl rand -base64 24`; app user = least privilege on `app-back` DB |
| **DB backup user/pass** (`BACKUP_DB_*`) | app-*, mysql | `openssl rand -base64 24`; SELECT/LOCK-only (granted by MySQL initdb script) |
| **Redis password** (`redis-auth`, `REDIS_PASSWORD`) | redis, app-* | `openssl rand -base64 24` |
| **SeaweedFS S3 keys** — app-files identity (`AWS_*` in `app-back-app`) + admin (`seaweedfs-s3-admin`) + identities config (`seaweedfs-s3-config`) | app-*, seaweedfs | `openssl rand -hex 20`; build `config.json` of identities (see below) |
| **Registry push creds (CI)** + **htpasswd** (`registry-htpasswd`) | (App repo secret) / registry | `htpasswd -nbB ci '<pass>' > htpasswd` → seal file as key `htpasswd` |
| **Registry pull secret** (`registry-pull`, dockerconfigjson) | app-dev, app-prod | see command below |
| **Registry S3 creds** (`registry-s3`) | registry | `accessKey`/`secretKey` = a SeaweedFS identity for the `registry` bucket |
| **MySQL root/replication** (`mysql-auth`) | mysql | `openssl rand -base64 24` each |
| **Grafana admin** (`grafana-admin`) | monitoring | `admin-user=admin`, `admin-password=$(openssl rand -base64 24)` |
| **App→Config write deploy key** | (App repo `lms-laravel-back`) | `ssh-keygen -t ed25519 -f deploy_key`; **public** key → `lms-k8s` *write* deploy key; **private** key → `lms-laravel-back` Actions secret |
| **ArgoCD→Config read-only repo cred** | (ArgoCD) | separate read-only deploy key or PAT; register via ArgoCD repo settings (never in Git) |

**Registry pull secret** (one per app namespace, then seal):
```bash
kubectl create secret docker-registry registry-pull \
  --docker-server=registry.lms.local \
  --docker-username=ci --docker-password='<pass>' \
  --namespace app-dev --dry-run=client -o yaml > /tmp/registry-pull.yaml
make seal-secret NS=app-dev IN=/tmp/registry-pull.yaml OUT=secrets/app-dev-registry-pull.yaml
```

**SeaweedFS S3 identities** (`seaweedfs-s3-config` → `config.json`):
```json
{ "identities": [
  { "name": "app-files", "credentials": [{"accessKey":"<AK>","secretKey":"<SK>"}],
    "actions": ["Read:app-files","Write:app-files","List:app-files"] },
  { "name": "backups", "credentials": [{"accessKey":"<AK>","secretKey":"<SK>"}],
    "actions": ["Read:mysql-backups","Write:mysql-backups","List:mysql-backups"] },
  { "name": "registry", "credentials": [{"accessKey":"<AK>","secretKey":"<SK>"}],
    "actions": ["Read:registry","Write:registry","List:registry"] },
  { "name": "admin", "credentials": [{"accessKey":"<AK>","secretKey":"<SK>"}],
    "actions": ["Admin","Read","Write","List"] }
]}
```
Put this JSON in a Secret keyed `config.json`, seal it as `seaweedfs-s3-config`.

**Back up the Sealed Secrets key** (losing it means resealing every secret):
```bash
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master.key   # store OFFLINE, encrypted. Do NOT commit.
```

---

## 4. Normal workflows

### Deploy (dev)
Merge to the dev branch in the **App repo**. CI builds, Trivy-scans, pushes the
image (tag = git SHA) and bumps `envs/dev/values.yaml`. ArgoCD `app-back-dev`
auto-syncs; the `migrate --force` hook runs before new pods roll.

### Promote to prod (no rebuild)
Run the App repo `promote-prod` workflow → it opens a PR bumping
`envs/prod/values.yaml` to the **already-tested** tag. Review, merge, then in
ArgoCD **manually sync** `app-back-prod` (prod is not auto-synced).

### Back up the DB
```bash
make backup ENV=prod          # on-demand Job from the CronJob
# scheduled automatically per envs/<env> backup.schedule -> mysql-backups/<env>/
```

### Restore / import a dump
```bash
# (a) existing backup object:
make restore ENV=dev KEY=dev/app-back-20260727T023000Z.sql.gz
# (b) an arbitrary local dump: upload first, then restore:
aws --endpoint-url https://... s3 cp ./mydump.sql.gz s3://mysql-backups/dev/mydump.sql.gz
make restore ENV=dev KEY=dev/mydump.sql.gz
# prod requires explicit confirmation:
make restore ENV=prod KEY=prod/....sql.gz CONFIRM_PROD=true
```
The restore Job optionally enters maintenance mode, imports, then runs
`migrate --force`. Afterwards set `restore.enabled=false` (re-sync) so it doesn't
re-run.

### Roll back a deploy (primary, safe)
```bash
make rollback ENV=prod        # prints the exact steps:
# git revert the envs/<env> tag bump (PR for prod) -> ArgoCD syncs the old image,
# or: argocd app rollback app-back-prod <history-id>
```

### Roll back a migration (manual, guarded, destructive)
```bash
make backup ENV=prod          # ALWAYS back up first
make migrate-rollback ENV=prod STEP=1 CONFIRM_PROD=true
# then set migrateRollback.enabled=false and re-sync
```
Combined runbook: roll the **image** back first (fast, safe); only roll
**migrations** if the old code is incompatible with the new schema — and note
not all migrations are reversible.

### View dashboards
`https://grafana.lms.local` (admin from `grafana-admin`). Prometheus alerts in
Alertmanager; ArgoCD UI at `https://argocd.lms.local`.

---

## 5. Validate before committing
```bash
make lint ENV=dev
make validate ENV=dev     # kubeconform schema validation
make security             # kube-linter / kubesec / checkov / trivy (see SECURITY-REVIEW.md)
```
