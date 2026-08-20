NAMESPACE ?= rhdh
VERSION ?= 1.9
ORCH ?= false
PLUGINS ?=
USE_CONTAINER ?= false
CATALOG_INDEX_TAG ?=
RUNNER_IMAGE ?= quay.io/rhdh-community/rhdh-e2e-runner:main
OSL_RELEASE ?=
ORCH_NAMESPACE ?= orchestrator

export CATALOG_INDEX_TAG

# Build deploy flags
DEPLOY_FLAGS = --namespace $(NAMESPACE)
ifeq ($(ORCH),true)
DEPLOY_FLAGS += --with-orchestrator
endif
ifneq ($(PLUGINS),)
DEPLOY_FLAGS += --plugins $(PLUGINS)
endif

# ── Deploy ────────────────────────────────────────────────────────────────────

.PHONY: deploy-helm install-operator deploy-operator

deploy-helm: ## Deploy RHDH via Helm (ORCH=1 for orchestrator, USE_CONTAINER=1 to run in container)
ifeq ($(USE_CONTAINER),true)
	$(MAKE) run-in-runner CMD="./deploy.sh helm $(VERSION) $(DEPLOY_FLAGS)"
else
	./deploy.sh helm $(VERSION) $(DEPLOY_FLAGS)
endif

install-operator: ## Install RHDH operator on cluster (one-time, runs in container)
	$(MAKE) run-in-runner CMD="source operator/install-operator.sh $(VERSION)"

deploy-operator: ## Deploy RHDH instance via Operator (ORCH=1 for orchestrator, USE_CONTAINER=1 to run in container)
ifeq ($(USE_CONTAINER),true)
	$(MAKE) run-in-runner CMD="./deploy.sh operator $(VERSION) $(DEPLOY_FLAGS)"
else
	./deploy.sh operator $(VERSION) $(DEPLOY_FLAGS)
endif

# ── Cleanup ───────────────────────────────────────────────────────────────────

.PHONY: undeploy-helm undeploy-operator undeploy-infra undeploy-plugins clean

undeploy-helm: ## Uninstall Helm RHDH release and all cluster resources (PLUGINS=keycloak,lighthouse to also teardown plugin infra)
ifdef PLUGINS
	./teardown.sh helm --namespace $(NAMESPACE) --plugins $(PLUGINS)
else
	./teardown.sh helm --namespace $(NAMESPACE)
endif

undeploy-operator: ## Remove Operator RHDH deployment and all cluster resources (PLUGINS=keycloak,lighthouse to also teardown plugin infra)
ifdef PLUGINS
	./teardown.sh operator --namespace $(NAMESPACE) --plugins $(PLUGINS)
else
	./teardown.sh operator --namespace $(NAMESPACE)
endif

undeploy-plugins: ## Teardown plugin infrastructure only, leave RHDH running (PLUGINS=keycloak,lighthouse)
ifndef PLUGINS
	$(error PLUGINS is required, e.g. make undeploy-plugins PLUGINS=keycloak,lighthouse)
endif
	TEARDOWN=true NAMESPACE=$(NAMESPACE) bash scripts/config-plugins.sh $(PLUGINS)

undeploy-infra: ## Uninstall orchestrator infra chart
	helm uninstall orchestrator-infra -n $(NAMESPACE) || true

clean: ## Delete the entire namespace (removes everything)
	oc delete project $(NAMESPACE) --ignore-not-found

# ── Orchestrator / OSL RC smoke ───────────────────────────────────────────────

.PHONY: prepare-osl setup-orchestrator cleanup cleanup-full osl-regression

prepare-osl: ## Mirror pre-release OSL images (OSL_RELEASE=1.39.0.CR1)
ifndef OSL_RELEASE
	$(error OSL_RELEASE is required, e.g. make prepare-osl OSL_RELEASE=1.39.0.CR1)
endif
	./prepare-osl-internal.sh --release $(OSL_RELEASE)

setup-orchestrator: ## Full RHDH + orchestrator setup (VERSION, ORCH_NAMESPACE, OSL_RELEASE)
	./setup-orchestrator.sh $(VERSION) --namespace $(ORCH_NAMESPACE) $(if $(filter-out ,$(OSL_RELEASE)),--prepare-internal-osl $(OSL_RELEASE))

cleanup: ## Clean RHDH/orchestrator/OSL resources and operators from ORCH_NAMESPACE
	./cleanup.sh --namespace $(ORCH_NAMESPACE) --include-operators

cleanup-full: ## Full cleanup: operators + related namespaces
	./cleanup.sh --namespace $(ORCH_NAMESPACE) --include-operators --delete-namespace

osl-regression: ## Cleanup + prepare OSL + deploy + 4-test smoke (VERSION, OSL_RELEASE; ORCH_NAMESPACE must be orchestrator)
ifndef OSL_RELEASE
	$(error OSL_RELEASE is required, e.g. make osl-regression VERSION=next OSL_RELEASE=1.39.0.CR1)
endif
	./run-osl-regression.sh --all --rhdh $(VERSION) --osl-release $(OSL_RELEASE) --namespace $(ORCH_NAMESPACE) \
		$(if $(filter 1,$(ALLOW_RELATIVE_SERVICE_URL)),--allow-relative-service-url,)

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

logs: ## Tail RHDH pod logs
	oc logs -f -l 'app.kubernetes.io/name=developer-hub' -n $(NAMESPACE) --tail=100

url: ## Print the RHDH URL
	@CLUSTER_ROUTER_BASE=$$(oc get route console -n openshift-console -o=jsonpath='{.spec.host}' | sed 's/^[^.]*\.//'); \
	echo "http://redhat-developer-hub-$(NAMESPACE).$${CLUSTER_ROUTER_BASE}"

# ── Runner ────────────────────────────────────────────────────────────────────

.PHONY: run-in-runner

run-in-runner: ## Run a command inside the e2e-runner container (requires oc login on host)
ifndef CMD
	$(error CMD is required)
endif
	$(eval K8S_CLUSTER_URL := $(shell oc whoami --show-server))
	$(eval K8S_CLUSTER_TOKEN := $(shell oc whoami --show-token))
	podman run --rm \
		-v $(CURDIR):/workspace:z \
		-w /workspace \
		-e KUBECONFIG=/tmp/.kube/config \
		$(RUNNER_IMAGE) \
		bash -c 'mkdir -p /tmp/.kube && oc login --token=$(K8S_CLUSTER_TOKEN) --server=$(K8S_CLUSTER_URL) --insecure-skip-tls-verify=true && source .env && $(CMD)'

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
