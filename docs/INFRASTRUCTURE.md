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

> **Ordering gotcha.** `argocd repo add` is a *client* command that needs a
> running, logged-in ArgoCD — it cannot run before install (you'll get
> `Argo CD server address unspecified`). So the read-only deploy key is split in
> two: generate it + add it to GitHub *up front* (step 0), but `repo add` it into
> ArgoCD only *after* install and login (step 3).

```bash
# 0. Prep the read-only deploy key for THIS repo (no ArgoCD needed yet).
#    Repo URLs are already set to git@github.com:zhuravlenko2555dev/lms-k8s.git.
ssh-keygen -t ed25519 -C "argocd-ro@lms-k8s" -f argocd-lms-k8s-ro -N ""
gh repo deploy-key add argocd-lms-k8s-ro.pub \
  --repo zhuravlenko2555dev/lms-k8s --title argocd-readonly   # NO --allow-write => read-only

# 1. Install ArgoCD out-of-band (pin the chart version), apply projects + roots.
make bootstrap-argocd            # helm install argocd + apply projects + roots
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s

# 2. Log the CLI into ArgoCD (fixes "server address unspecified"). During bootstrap
#    DNS/CA trust may not be wired yet, so reach it via port-forward:
kubectl -n argocd port-forward svc/argocd-server 8080:443 &   # background
PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$PW" --insecure
#    (later, once *.lms.local resolves + CA is trusted: argocd login argocd.lms.local)

# 3. Register repo creds. Now that ArgoCD is up + logged in, repo add works:
argocd repo add git@github.com:zhuravlenko2555dev/lms-k8s.git \
  --ssh-private-key-path ./argocd-lms-k8s-ro --name lms-k8s
argocd repo list                 # STATUS: Successful
rm argocd-lms-k8s-ro argocd-lms-k8s-ro.pub   # key now lives in the argocd namespace
#    Also configure lms-laravel-back's write deploy key + registry push creds (App repo side).

# 4. Seal the platform secrets ArgoCD needs (seaweedfs-s3-config, registry-htpasswd/
#    registry-s3, mysql-auth, redis-auth, grafana-admin) and commit under secrets/
#    (see USAGE.md). ArgoCD then brings up the platform by waves.

# 5. Run lms-laravel-back CI once to push the first image; it bumps envs/dev/values.yaml.

# 6. Seal the app secrets (app-back-app, registry-pull) for app-dev/app-prod, commit.
#    ArgoCD syncs app-back-dev automatically.

# 7. Verify: TLS (curl the hosts), Grafana dashboards, a backup, a restore, a rollback.
```

Until step 3 completes, the root app-of-apps applied by `make bootstrap-argocd`
will show a repo/auth error against `lms-k8s` — expected; they reconcile to
healthy once the repo cred is registered.

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
