# =============================================================================
# lms-k8s (Config repo) operations. Requires: helm, kubectl, kubeseal,
# kubeconform, plus (for security) kube-linter/kubesec/checkov/trivy/hadolint.
# Override the kube context with:  make <target> KUBECONFIG=/path CTX=my-ctx
# =============================================================================
SHELL := /usr/bin/env bash
CTX ?=
KCTL := kubectl $(if $(CTX),--context $(CTX),)
ENV ?= dev
NS  ?= app-$(ENV)
CHART := chart
VALUES := envs/$(ENV)/values.yaml

.DEFAULT_GOAL := help
.PHONY: help lint validate template seal-secret bootstrap-argocd platform \
        apps backup restore migrate-rollback rollback security

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}'

## ---- validate / lint -------------------------------------------------------
lint: ## helm lint the app chart against an env
	helm lint $(CHART) -f $(VALUES)

template: ## Render the app chart for ENV to stdout
	helm template app-back-$(ENV) $(CHART) -f $(VALUES) --namespace $(NS)

validate: ## Render + schema-validate all manifests (kubeconform)
	helm template app-back-$(ENV) $(CHART) -f $(VALUES) --namespace $(NS) \
	  | kubeconform -strict -ignore-missing-schemas -summary \
	      -schema-location default \
	      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

## ---- secrets ---------------------------------------------------------------
seal-secret: ## Seal a plaintext Secret. Usage: make seal-secret NS= IN= OUT=
	@test -n "$(IN)" && test -n "$(OUT)" || { echo "set IN= and OUT="; exit 1; }
	kubeseal --format yaml \
	  --controller-namespace sealed-secrets \
	  --controller-name sealed-secrets-controller \
	  < $(IN) > $(OUT)
	@echo "sealed -> $(OUT) (safe to commit; delete the plaintext $(IN))"

## ---- bootstrap / deploy ----------------------------------------------------
bootstrap-argocd: ## Install ArgoCD out-of-band with hardened values (pin --version)
	helm repo add argo https://argoproj.github.io/argo-helm
	helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
	  -f argocd/install/values.yaml
	$(KCTL) apply -f argocd/projects/
	$(KCTL) apply -f argocd/root-platform.yaml
	$(KCTL) apply -f argocd/root-app.yaml

platform: ## (Re)apply the platform app-of-apps root
	$(KCTL) apply -f argocd/root-platform.yaml

apps: ## (Re)apply the per-env ApplicationSet
	$(KCTL) apply -f argocd/root-app.yaml

## ---- data ops --------------------------------------------------------------
backup: ## Trigger an on-demand DB backup Job from the CronJob (ENV=dev|prod)
	$(KCTL) -n $(NS) create job --from=cronjob/app-back-backup app-back-backup-manual-$$(date +%s)

restore: ## Restore a dump. Usage: make restore ENV= KEY=dev/app-back-....sql.gz [CONFIRM_PROD=true]
	@test -n "$(KEY)" || { echo "set KEY=<s3 object key>"; exit 1; }
	helm upgrade --install app-back-$(ENV) $(CHART) -f $(VALUES) --namespace $(NS) \
	  --set restore.enabled=true --set restore.objectKey='$(KEY)' \
	  $(if $(filter prod,$(ENV)),--set restore.confirmProd=$(CONFIRM_PROD),)
	@echo "Restore Job created. Watch: $(KCTL) -n $(NS) logs -l app.kubernetes.io/component=restore -f"
	@echo "Afterwards re-sync ArgoCD to clear restore.enabled (or set it false)."

## ---- rollback --------------------------------------------------------------
rollback: ## Deploy rollback = revert the image tag in envs/$(ENV)/values.yaml in Git, then ArgoCD syncs.
	@echo "Deploy rollback is a Git operation (safe, primary path):"
	@echo "  1) git revert the commit that bumped envs/$(ENV)/values.yaml (or edit image.tag back)."
	@echo "  2) push; ArgoCD ($(ENV)) syncs. For prod, merge the revert PR then sync manually."
	@echo "  Alternatively: argocd app rollback app-back-$(ENV) <history-id>"

migrate-rollback: ## MANUAL migration rollback Job. Usage: make migrate-rollback ENV= STEP=1 [CONFIRM_PROD=true]
	@echo "!! migrate:rollback can be DESTRUCTIVE/irreversible. Take a backup first: make backup ENV=$(ENV)"
	helm upgrade --install app-back-$(ENV) $(CHART) -f $(VALUES) --namespace $(NS) \
	  --set migrateRollback.enabled=true --set migrateRollback.step=$(or $(STEP),1) \
	  $(if $(filter prod,$(ENV)),--set migrateRollback.confirmProd=$(CONFIRM_PROD),)
	@echo "Rollback Job created. Then disable it again (set migrateRollback.enabled=false / re-sync)."

## ---- security --------------------------------------------------------------
security: ## Run the manifest/security scanners (see docs/SECURITY-REVIEW.md)
	-helm lint $(CHART) -f $(VALUES)
	-$(MAKE) validate
	-helm template app-back-$(ENV) $(CHART) -f $(VALUES) --namespace $(NS) | kube-linter lint -
	-helm template app-back-$(ENV) $(CHART) -f $(VALUES) --namespace $(NS) | kubesec scan /dev/stdin
	-checkov -d chart --framework helm --quiet
	-trivy config --severity HIGH,CRITICAL .
