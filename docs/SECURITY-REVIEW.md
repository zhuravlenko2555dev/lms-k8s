# lms-k8s — Security Review (Config repo)

**§0.B** deliverable. Two parts: (1) the scanning tooling and how to run it, and
(2) a **control → threat** explanation of every hardening decision, plus residual
risks and single points of failure.

---

## 1. Tooling

These scanners were **not installed in the generation environment**, so results
could not be captured here. Run them from the repo root — each command is exact.
`make security` runs the manifest set in one shot.

| Tool | Scope | Command |
|---|---|---|
| **helm lint** | chart sanity | `helm lint chart -f envs/dev/values.yaml` |
| **kubeconform** | schema/CRD validation | `helm template app-back-dev chart -f envs/dev/values.yaml -n app-dev \| kubeconform -strict -ignore-missing-schemas -summary` |
| **kube-linter** | manifest best practices/security | `helm template app-back-dev chart -f envs/dev/values.yaml -n app-dev \| kube-linter lint -` |
| **kubesec** | pod security score | `helm template app-back-dev chart -f envs/dev/values.yaml -n app-dev \| kubesec scan /dev/stdin` |
| **checkov** | IaC policy | `checkov -d chart --framework helm` and `checkov -d platform --framework kubernetes` |
| **Trivy (config/IaC)** | misconfig scan | `trivy config --severity HIGH,CRITICAL .` |
| **Trivy (image)** | image CVEs — gated in **App repo** CI | `trivy image --severity HIGH,CRITICAL --exit-code 1 registry.lms.local/app-back:<sha>` |
| **hadolint** | Dockerfile — lives in the **App repo** | `hadolint docker/Dockerfile` |

> **Image CVE scanning and Dockerfile linting are the App repo's responsibility**
> (Trivy gate on HIGH/CRITICAL before push; hadolint in CI). This repo consumes
> only digest-pinnable tags from that pipeline.

Expected material findings to triage: kube-linter may warn on the SeaweedFS
bucket-create Job image (`amazon/aws-cli`) not being digest-pinned, and on
upstream platform charts whose pod security we set via values but cannot fully
control. Pin those and re-run before calling clean.

---

## 2. Control → threat analysis

### Workload hardening (app chart)
| Control | Where | Threat mitigated |
|---|---|---|
| `runAsNonRoot` + uid/gid 10001 | `podSecurityContext`, all workloads | A container-breakout exploit lands as an unprivileged user, not root — blocks most host-level escalation. |
| `readOnlyRootFilesystem: true` (writable paths are `emptyDir`) | all containers | Attacker cannot persist a webshell/binary on the image filesystem; tampering is ephemeral and lost on restart. |
| `allowPrivilegeEscalation: false` + `capabilities.drop: [ALL]` | all containers | No setuid/`CAP_*` path to gain privileges; removes `CAP_NET_RAW` (ARP/DNS spoofing) etc. |
| `seccompProfile: RuntimeDefault` | pods + containers | Blocks dangerous/obscure syscalls used by kernel exploits. |
| Resource `requests`/`limits` everywhere | all workloads | Prevents a compromised or buggy pod from starving neighbours (noisy-neighbour / resource-exhaustion DoS). |
| `automountServiceAccountToken: false` | `rbac.yaml` | The app never calls the K8s API, so no token is mounted — a compromised pod can't use it to pivot against the cluster API. |
| No Role/RoleBinding granted | `rbac.yaml` | Least privilege: even if a token were present it would grant nothing. |
| nginx `server_tokens off`, strips `X-Powered-By`/`Server` | `configmap.yaml`, middlewares | Reduces fingerprinting that guides targeted exploits. |

### Network
| Control | Where | Threat mitigated |
|---|---|---|
| **Default-deny** ingress+egress, then explicit allows | `networkpolicy.yaml` | Stops lateral movement: a compromised web pod can reach only MySQL/Redis/S3/DNS, nothing else — and only Traefik/Prometheus can reach it. |
| DNS-only egress allow to kube-system | `networkpolicy.yaml` | Keeps name resolution working under default-deny without opening broad egress (limits data exfiltration channels). |
| Redis/MySQL chart `allowExternal: false` + netpol | platform values | Datastores accept only labelled clients, not arbitrary in-cluster pods. |
| **PSA `restricted`** on `app-dev`/`app-prod` | `platform/namespaces` | Admission-time rejection of privileged/hostPath/hostNetwork pods — a defense that holds even if a chart value regresses. |
| `ResourceQuota` + `LimitRange` per env | `platform/namespaces` | Bounds dev↔prod blast radius; a runaway dev cannot exhaust cluster capacity needed by prod. |

### TLS / ingress
| Control | Where | Threat mitigated |
|---|---|---|
| TLS everywhere via cert-manager **private CA** | `cluster-issuer.yaml`, ingresses | Encrypts all external traffic; MITM on the LAN can't read/alter sessions. `.local` can't use Let's Encrypt, so a private CA is the correct choice; a one-switch LE path is shipped for a future public domain. |
| HTTP→HTTPS redirect + **HSTS** (preload) | Traefik middlewares | Eliminates plaintext downgrade and protocol-stripping attacks. |
| Secure headers (frameDeny, nosniff, referrer-policy, permissions-policy) | middlewares | Clickjacking, MIME-sniffing, referrer leakage. |
| **Rate limiting** at Traefik | middlewares | Blunts brute-force and volumetric abuse of the API/login. |
| Registry behind **TLS + htpasswd auth** | `registry/values.yaml` | Only authenticated CI can push; pulls require the imagePullSecret — prevents anonymous image tampering/poisoning. |

### Supply chain / secrets
| Control | Where | Threat mitigated |
|---|---|---|
| **No plaintext secrets in Git** — SealedSecrets only | `secrets/`, `.gitignore` | Repo leak does not expose credentials; only the in-cluster controller can decrypt. Verified: scan found no private keys or literal passwords, only placeholders. |
| Image **digest pinning** supported (`image.digest`) | chart | Defeats tag-mutation attacks (a re-pushed `:tag` can't silently change what runs). |
| Upstream chart versions **pinned** | `argocd/applications/*` | Reproducible installs; blocks a malicious/broken newer chart from auto-applying. |
| App→Config **write** deploy key; ArgoCD→Config **read-only**; CI push vs cluster pull creds split | USAGE §3 | Least privilege per identity: CI can't read prod secrets, ArgoCD can't push to Git, a stolen pull secret can't push images. |
| Trivy HIGH/CRITICAL **gate** + `composer/npm audit` | App repo CI | Known-vulnerable images/deps never reach the registry. |

### GitOps / ArgoCD
| Control | Where | Threat mitigated |
|---|---|---|
| No anonymous access, `policy.default: role:readonly`, admin by group | `argocd/install/values.yaml` | Prevents unauthenticated or over-broad changes to cluster state. |
| **AppProjects** restrict source repo, destination namespaces, resource kinds | `argocd/projects/*` | A compromised app manifest can't deploy cluster-scoped resources or into other namespaces; app projects are namespaced-only. |
| **prod manual/PR-gated** + deny sync-window | `root-app.yaml`, `app-prod.yaml` | No automated change reaches prod; a human reviews and syncs — reduces blast radius of a bad commit. |
| Migrations only via **pre-upgrade hook**; rollback only via **manual guarded Job** (prod needs `confirmProd`) | `migrate-hook-job.yaml`, `migrate-rollback-job.yaml` | A failed migration aborts the rollout before serving; destructive `migrate:rollback` can never fire automatically or unconfirmed in prod. |

### Data protection
| Control | Where | Threat mitigated |
|---|---|---|
| Least-privilege **backup DB user** (SELECT/LOCK only) | `mysql/values.yaml`, backup Job | A leaked backup credential can read for dumps but cannot write/drop data. |
| Restore uses the **owner** user, backups the **backup** user | restore/backup Jobs | Separation of duties between read (backup) and write (restore). |
| Scheduled backups + retention → SeaweedFS | backup CronJob | Recover from data loss/ransomware/bad migration; tested restore is the recovery path for the MySQL SPOF. |

---

## 3. Residual risks & single points of failure (honest)

- **Single-instance MySQL** (`architecture: standalone`) — a node/PV loss causes
  downtime and up-to-RPO data loss. *Mitigation:* daily backups + tested restore;
  RPO = backup interval. *Not* HA. Switch to managed/replicated MySQL for HA
  (documented switch in `INFRASTRUCTURE.md`). **This is the top SPOF.**
- **SeaweedFS master/volume single replica** — underlies registry, backups and
  app files; its loss is broad. Scale replicas / add off-cluster backup copies.
- **Private CA root key** lives in-cluster (`lms-local-ca` secret). If the cluster
  is compromised, the CA is too. Keep the root offline for a real deployment and
  issue an intermediate; rotate before expiry (alert `CertExpiringSoon` covers it).
- **Sealed Secrets controller key** is the master decryption key — back it up
  **offline** (USAGE §3). Losing it forces resealing every secret; leaking it
  exposes all sealed secrets. Rotate periodically.
- **Self-hosted runner** trusts the private CA and holds the App→Config write key
  and registry push creds — a compromised runner can push images and bump tags
  (dev auto-syncs). Isolate the runner, scope its token, and rely on prod's
  manual gate as the backstop.
- **In-cluster plaintext to SeaweedFS/registry S3** (`secure: false`) is acceptable
  only because it stays on the pod network under NetworkPolicy; external exposure
  must always terminate TLS at Traefik.
- **ArgoCD is a high-value target** (it can change everything). Enforce SSO/RBAC,
  restrict the UI (`argocd.lms.local` behind TLS), and audit `AppProject` scope.

**Acceptance:** non-root + read-only FS + dropped caps + no-priv-esc +
RuntimeDefault + resource limits; PSA restricted + default-deny netpol + quotas;
pinned charts + digest-capable images + Trivy/audit gates (App repo); TLS
everywhere with HSTS/headers/rate-limit; registry TLS+auth; ArgoCD no-anon +
RBAC + AppProjects; **no plaintext secrets** (verified); least-privilege DB user
with tested backup/restore/rollback; monitoring + alerts. Residual SPOFs above
are documented and, where not eliminated, mitigated.
