# lms-k8s — Infrastructure

GitOps Config repo (`git@github.com:zhuravlenko2555dev/lms-k8s.git`) for a
**Laravel 12 API + admin** backend (with a Nuxt frontend planned as a separate
repo later) on **full Kubernetes**, managed by **ArgoCD**. This repo is the
single source of truth ArgoCD watches; the App repo
(`git@github.com:zhuravlenko2555dev/lms-laravel-back.git`) only builds the image
and bumps the tag here.

## Architecture

```
 Developer / CI (App repo)                 Config repo (this repo)            Cluster
 ─────────────────────────                 ───────────────────────           ───────
 merge -> build image (SHA) ─push TLS─▶  registry.lms.local                 Traefik ┐
                    │                                                                │ TLS (private CA)
                    └─write deploy key─▶  envs/dev/values.yaml  ─ArgoCD(ro)─▶  app-dev / app-prod
                                          envs/prod/values.yaml (PR-gated)          │
                                                                                    ▼
   ArgoCD app-of-apps ─▶ platform/ (waves): cert-manager, traefik, sealed-secrets,
                          seaweedfs, registry, redis, mysql, monitoring
```

- **Two AppProjects for the app** (`app-dev`, `app-prod`) + one `platform`.
- **dev** auto-syncs (prune+selfHeal). **prod** is manual/PR-gated (a human syncs
  after the promote PR merges; a deny sync-window blocks automation).
- **TLS** for `*.lms.local` is issued by an **in-cluster private CA** (cert-manager)
  because Let's Encrypt cannot validate a non-public `.local` domain.

## Repository layout

| Path | Purpose |
|---|---|
| `chart/` | Application Helm chart (web, worker, scheduler, migrate hook, migrate-rollback, backup, restore, ingress, netpol, rbac, servicemonitor, hpa, pdb). |
| `envs/{dev,prod}/values.yaml` | Per-env overrides + the current image tag (tag written by CI/promotion). |
| `platform/` | ArgoCD-managed platform component values + extra manifests. |
| `argocd/` | Install values, AppProjects, `root-platform.yaml`, `root-app.yaml`, child `applications/`. |
| `secrets/` | **SealedSecrets only.** `examples/` holds placeholder templates. |
| `Makefile` | bootstrap, lint/validate, seal-secret, backup, restore, rollback, migrate-rollback, security. |

## Sync-wave order (platform bring-up)

| Wave | Components | Why |
|---|---|---|
| -1 | namespaces (PSA restricted + quota + limitrange) | Land guardrails before workloads. |
| 0  | cert-manager (+private-CA ClusterIssuer), Traefik, sealed-secrets | TLS, ingress and secret decryption must exist first. |
| 1  | SeaweedFS (+buckets) | Object storage backs registry, backups, app files. |
| 2  | registry | Needs SeaweedFS S3 as its blob backend. |
| 3  | Redis, MySQL, monitoring | Data + observability. |
| app | app-back-dev / app-back-prod | Needs all of the above. |

## Bootstrap (one time)

Prereqs on the operator/runner host: `kubectl`, `helm`, `kubeseal`, cluster
access, and **trust of the private CA** once it exists (see USAGE.md), plus
`*.lms.local` resolving to the Traefik LB IP.

```bash
# 0. Repo URLs are already set to git@github.com:zhuravlenko2555dev/lms-k8s.git
#    (this Config repo). Register it in ArgoCD with a read-only SSH deploy key
#    (argocd repo add git@github.com:zhuravlenko2555dev/lms-k8s.git --ssh-private-key-path ...).

# 1. Install ArgoCD out-of-band (pin the chart version), apply projects + roots.
make bootstrap-argocd            # helm install argocd + apply projects + roots

# 2. ArgoCD brings up the platform by waves. Seal the platform secrets it needs
#    (seaweedfs-s3-config, registry-htpasswd/registry-s3, mysql-auth, redis-auth,
#    grafana-admin) and commit them under secrets/ (see USAGE.md), then let it sync.

# 3. Configure ArgoCD repo creds: read-only deploy key for this repo (lms-k8s).
#    Configure lms-laravel-back's write deploy key + registry push creds (App repo side).

# 4. Run lms-laravel-back CI once to push the first image; it bumps envs/dev/values.yaml.

# 5. Seal the app secrets (app-back-app, registry-pull) for app-dev/app-prod, commit.
#    ArgoCD syncs app-back-dev automatically.

# 6. Verify: TLS (curl the hosts), Grafana dashboards, a backup, a restore, a rollback.
```

## Operations runbook

- **Deploy (dev):** merge in App repo → CI pushes image + bumps `envs/dev` → ArgoCD auto-syncs.
- **Promote to prod:** App repo `promote-prod` opens a PR bumping `envs/prod` to the tested tag (no rebuild) → merge → sync `app-back-prod` manually in ArgoCD.
- **Backup:** `make backup ENV=prod` (or wait for the CronJob) → object in `mysql-backups/prod/`.
- **Restore/import:** `make restore ENV=dev KEY=dev/app-back-....sql.gz` (prod adds `CONFIRM_PROD=true`).
- **Deploy rollback:** `git revert` the `envs/<env>` tag bump (or `argocd app rollback`). Primary, safe path.
- **Migration rollback:** `make migrate-rollback ENV=dev STEP=1` — manual, guarded, destructive; back up first.
- **Dashboards:** `https://grafana.lms.local`.

## Documented switches / SPOFs

- **External MySQL:** disable `argocd/applications/41-mysql.yaml` and set `config.DB_HOST` to the managed endpoint; keep the backup/restore Jobs.
- **Public TLS:** apply `letsencrypt-prod` ClusterIssuer and set `ingress.clusterIssuer: letsencrypt-prod` in env values once a public domain exists.
- **SPOFs:** single-instance MySQL and single-replica SeaweedFS master are single points of failure — mitigated by tested backups/restore, not HA. See `SECURITY-REVIEW.md`.
