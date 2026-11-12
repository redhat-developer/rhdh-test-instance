NAMESPACE ?= rhdh
VERSION ?= 2.2
PLUGINS ?=
USE_CONTAINER ?= false
CATALOG_INDEX_TAG ?=
CATALOG_INDEX_IMAGE ?=
RHDH_IMAGE ?=
RUNNER_IMAGE ?= quay.io/rhdh-community/rhdh-e2e-runner:main
FORCE ?= false
KEYCLOAK_NS ?= rhdh-keycloak
OPERATOR_NAMESPACE ?= rhdh-operator

export CATALOG_INDEX_TAG
export CATALOG_INDEX_IMAGE
export RHDH_IMAGE
export KEYCLOAK_NS
export OPERATOR_NAMESPACE

# ── Deploy flags ──────────────────────────────────────────────────────────────
# PLUGINS=<list>   Comma-separated optional plugins, "all", or "all,-name".
#                  Available: kubernetes, bulk-import, intelligent-assistant,
#                  orchestrator, scorecard, rbac, lighthouse (Keycloak is always on).

DEPLOY_FLAGS = --namespace $(NAMESPACE)
ifneq ($(PLUGINS),)
DEPLOY_FLAGS += --plugins $(PLUGINS)
endif

# ── Deploy ────────────────────────────────────────────────────────────────────

.PHONY: deploy-helm install-operator deploy-operator

deploy-helm: ## Deploy RHDH via Helm (PLUGINS=all,-orchestrator, USE_CONTAINER=true to run in container)
ifeq ($(USE_CONTAINER),true)
	$(MAKE) run-in-runner CMD="./deploy.sh helm $(VERSION) $(DEPLOY_FLAGS)"
else
	./deploy.sh helm $(VERSION) $(DEPLOY_FLAGS)
endif

install-operator: ## Install the RHDH operator via OLM (runs in the e2e-runner container)
	$(MAKE) run-in-runner CMD="bash operator/install-operator.sh $(VERSION)"

deploy-operator: ## Deploy RHDH via Operator (PLUGINS=..., USE_CONTAINER=true to run in container)
ifeq ($(USE_CONTAINER),true)
	$(MAKE) run-in-runner CMD="./deploy.sh operator $(VERSION) $(DEPLOY_FLAGS)"
else
	./deploy.sh operator $(VERSION) $(DEPLOY_FLAGS)
endif

# ── Cleanup ───────────────────────────────────────────────────────────────────

.PHONY: undeploy-helm undeploy-operator undeploy-plugins undeploy-keycloak undeploy-infra uninstall-operator clean

undeploy-helm: ## Uninstall Helm RHDH release and all cluster resources (PLUGINS=lighthouse to also teardown plugin infra)
ifdef PLUGINS
	./teardown.sh helm --namespace $(NAMESPACE) --plugins $(PLUGINS)
else
	./teardown.sh helm --namespace $(NAMESPACE)
endif

undeploy-operator: ## Remove Operator RHDH deployment and all cluster resources
ifdef PLUGINS
	./teardown.sh operator --namespace $(NAMESPACE) --plugins $(PLUGINS)
else
	./teardown.sh operator --namespace $(NAMESPACE)
endif

undeploy-plugins: ## Teardown plugin infrastructure only, leave RHDH running (PLUGINS=lighthouse)
ifndef PLUGINS
	$(error PLUGINS is required, e.g. make undeploy-plugins PLUGINS=lighthouse. Use make undeploy-keycloak for the shared Keycloak.)
endif
	TEARDOWN=true NAMESPACE=$(NAMESPACE) KEYCLOAK_NS=$(KEYCLOAK_NS) bash scripts/config-plugins.sh $(PLUGINS)

undeploy-keycloak: ## Remove the shared Keycloak (only after all instances are gone)
	TEARDOWN=true NAMESPACE=$(NAMESPACE) KEYCLOAK_NS=$(KEYCLOAK_NS) bash scripts/config-plugins.sh keycloak

deploy-keycloak: ## Pre-create the shared Keycloak, realm and test users (run once before Test Day)
	NAMESPACE=$(NAMESPACE) KEYCLOAK_NS=$(KEYCLOAK_NS) bash -c 'source scripts/config-plugins.sh; deploy_keycloak; create_users_and_groups_keycloak'

undeploy-infra: ## Uninstall orchestrator infra chart
	helm uninstall orchestrator-infra -n $(NAMESPACE) || true

uninstall-operator: ## Uninstall the RHDH operator, its OLM v1 resources and the operator namespace (FORCE=true despite running instances)
	@if [ -n "$$(oc get backstages.rhdh.redhat.com --all-namespaces -o name 2>/dev/null)" ] && [ "$(FORCE)" != "true" ]; then \
		echo "Error: Backstage instances still exist. Deleting the operator also removes the" >&2; \
		echo "RHDH CRDs and every instance built from them:" >&2; \
		oc get backstages.rhdh.redhat.com --all-namespaces >&2; \
		echo "Remove them with 'make clean NAMESPACE=<ns>' or re-run with FORCE=true." >&2; \
		exit 1; \
	fi
	@if oc api-resources --api-group=olm.operatorframework.io 2>/dev/null | grep -q "^clusterextensions "; then \
		oc delete clusterextension.olm.operatorframework.io rhdh --ignore-not-found; \
		for catalog in $$(oc get clustercatalog.olm.operatorframework.io -o name 2>/dev/null | grep '/rhdh-'); do \
			oc delete "$$catalog" --ignore-not-found; \
		done; \
	fi
	oc delete clusterrolebinding rhdh-installer-binding --ignore-not-found
	oc delete project $(OPERATOR_NAMESPACE) --ignore-not-found
	@echo "Operator uninstalled. The OLM v1 ClusterExtension took the RHDH CRDs and any remaining Backstage instances with it."

clean: ## Delete the namespace and the instance's cluster-scoped resources (keeps Keycloak and the operator)
	@TEARDOWN=true NAMESPACE=$(NAMESPACE) KEYCLOAK_NS=$(KEYCLOAK_NS) TIMEOUT=0 \
		bash -c 'source scripts/config-plugins.sh; uninstall_keycloak' || \
		echo "Warning: Could not remove the Keycloak client for $(NAMESPACE)."
	oc delete clusterrolebinding rhdh-kubernetes-plugin-$(NAMESPACE) --ignore-not-found
	oc delete project $(NAMESPACE) --ignore-not-found

# ── Verification ──────────────────────────────────────────────────────────────

.PHONY: verify-plugins smoke

verify-plugins: ## Render the deployment and run the real plugin installer locally (requires podman)
	bash scripts/verify-plugins.sh --version $(VERSION) --plugins "$(PLUGINS)"

# Route lookup shared by url and smoke (Helm and Operator).
RHDH_ROUTE_CMD = oc get route -n $(NAMESPACE) -o jsonpath='{range .items[*]}{.spec.to.name}{" "}{.spec.host}{" "}{.spec.tls.termination}{"\n"}{end}' | awk '/^(redhat|backstage)-developer-hub /{proto=($$3=="")?"http":"https"; print proto"://"$$2; exit}'

EXPECT_PLUGINS ?=
ABSENT_PLUGINS ?=

smoke: ## Playwright smoke checks against a deployed instance (EXPECT_PLUGINS / ABSENT_PLUGINS optional)
	@RHDH_BASE_URL="$$($(RHDH_ROUTE_CMD))" \
		EXPECT_PLUGINS="$(EXPECT_PLUGINS)" ABSENT_PLUGINS="$(ABSENT_PLUGINS)" PLUGINS="$(PLUGINS)" \
		ARTIFACT_DIR="$(CURDIR)/e2e/results-artifacts" \
		bash scripts/run-smoke.sh

# ── Status ────────────────────────────────────────────────────────────────────

.PHONY: status logs url

status: ## Show deployment status
	@echo "=== Namespace: $(NAMESPACE) ==="
	@oc get pods -n $(NAMESPACE) 2>/dev/null || echo "Namespace not found"
	@echo ""
	@echo "=== Helm Releases ==="
	@helm list -n $(NAMESPACE) 2>/dev/null || true
	@echo ""
	@echo "=== Orchestrator Operators ==="
	@oc get csv -n openshift-serverless-logic -o custom-columns='NAME:.metadata.name,VERSION:.spec.version,PHASE:.status.phase' 2>/dev/null || echo "Not installed"

logs: ## Tail RHDH pod logs (works for Helm and Operator)
	oc logs -f -l backstage.io/kubernetes-id=developer-hub -n $(NAMESPACE) --tail=100 -c backstage-backend

url: ## Print the RHDH URL (works for Helm and Operator)
	@$(RHDH_ROUTE_CMD)

# ── Runner ────────────────────────────────────────────────────────────────────

.PHONY: run-in-runner

run-in-runner: ## Run a command inside the e2e-runner container (requires oc login on host)
ifndef CMD
	$(error CMD is required)
endif
	K8S_CLUSTER_URL="$$(oc whoami --show-server)" K8S_CLUSTER_TOKEN="$$(oc whoami --show-token)" \
	podman run --rm \
		-v $(CURDIR):/workspace:z \
		-w /workspace \
		--tmpfs /run/rhdh:rw,mode=0700 \
		-e KUBECONFIG=/run/rhdh/kubeconfig -e TMPDIR=/run/rhdh \
		-e K8S_CLUSTER_URL -e K8S_CLUSTER_TOKEN \
		-e CATALOG_INDEX_IMAGE -e CATALOG_INDEX_TAG -e RHDH_IMAGE \
		-e KEYCLOAK_NS -e OPERATOR_NAMESPACE \
		-e RHDH_GITHUB_TOKEN -e SONARQUBE_API_KEY \
		-e ENABLE_OPENAI -e OPENAI_API_KEY \
		-e ENABLE_VLLM -e VLLM_URL -e VLLM_API_KEY \
		-e ENABLE_OLLAMA -e OLLAMA_URL \
		-e ENABLE_VERTEX_AI -e VERTEX_AI_PROJECT -e VERTEX_AI_LOCATION \
		$(RUNNER_IMAGE) \
		bash -c 'oc login --token="$$K8S_CLUSTER_TOKEN" --server="$$K8S_CLUSTER_URL" --insecure-skip-tls-verify=true >/dev/null && { [ ! -f .env ] || source .env; } && $(CMD)'

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
