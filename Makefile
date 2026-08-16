# Mac mini LLM home lab -- kind on podman, NGF ingress, swappable AI gateways.
#
#   make bootstrap            full build, standard profile, envoy gateway
#   make gateway GW=litellm   swap the AI gateway in place
#   make smoke                verify end to end

SHELL := /bin/bash
.DEFAULT_GOAL := help

S := ./scripts

# Overridable on the command line: make backends PROFILE=full GW=litellm
# Exported ONLY when non-empty -- an empty export would shadow the value in .env.
ifneq ($(strip $(PROFILE)),)
export PROFILE
endif
ifneq ($(strip $(GW)),)
export GATEWAY = $(strip $(GW))
endif

.PHONY: help
help: ## show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1;36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Variables:  PROFILE=lite|standard|full   GW=envoy|litellm|bifrost|none"

.PHONY: init
init: ## create .env from the example
	@if [[ -f .env ]]; then \
	  echo ".env exists, leaving it alone"; \
	elif [[ ! -f .env.example ]]; then \
	  echo "ERROR: .env.example is missing -- restore it from git" >&2; exit 1; \
	elif cp .env.example .env; then \
	  echo "created .env from .env.example"; \
	else \
	  echo "ERROR: could not create .env" >&2; exit 1; \
	fi

.PHONY: use-docker use-podman
use-docker: ## switch runtime to docker (refuses if a cluster would be stranded)
	@$(S)/switch-runtime.sh docker
use-podman: ## switch runtime to podman (refuses if a cluster would be stranded)
	@$(S)/switch-runtime.sh podman

.PHONY: preflight
preflight: ## check podman, memory, tools, host engine
	@$(S)/preflight.sh

.PHONY: up
up: ## create the kind cluster + CRDs + NGF ingress
	@$(S)/up.sh

.PHONY: recreate
recreate: ## delete and rebuild the cluster from scratch
	@RECREATE=1 $(S)/up.sh

.PHONY: build-vllm
build-vllm: ## build the vLLM CPU image for arm64 (slow, one time)
	@./images/vllm-cpu/build.sh

.PHONY: backends
backends: ## deploy model backends per PROFILE
	@$(S)/backends.sh

.PHONY: gateway
gateway: ## install/swap the AI gateway  (make gateway GW=litellm)
	@$(S)/gateway.sh $(GW)

.PHONY: bootstrap
bootstrap: preflight up backends gateway smoke ## everything, in order

.PHONY: rebuild
rebuild: ## destroy and rebuild everything from scratch (cluster + backends + gateway)
	@RECREATE=1 $(MAKE) bootstrap

.PHONY: smoke
smoke: ## end-to-end test through the ingress
	@$(S)/smoke.sh

.PHONY: preload-images
preload-images: ## pull images host-side and side-load into kind (ghcr workaround)
	@$(S)/preload-images.sh

.PHONY: doctor-registry
doctor-registry: ## diagnose registry 403 / pull failures
	@$(S)/doctor-registry.sh

.PHONY: versions
versions: ## compare pinned component versions against upstream latest
	@$(S)/versions.sh

.PHONY: verify-images
verify-images: ## confirm every image has a linux/arm64 manifest
	@$(S)/verify-images.sh

.PHONY: capture
capture: ## write full diagnostics to diagnostics.log (readable by Claude, no copy/paste)
	@$(S)/capture.sh

.PHONY: observability
observability: ## install kube-prometheus-stack + vLLM dashboard (heavy, opt-in)
	@$(S)/observability.sh

.PHONY: observability-down
observability-down: ## remove the observability stack
	@$(S)/observability-down.sh

.PHONY: grafana
grafana: ## port-forward Grafana to localhost:3000 (works without the NodePort)
	@echo "Grafana -> http://localhost:3000   login: admin / llm-lab   (ctrl-c to stop)"
	@kubectl --context kind-$${CLUSTER_NAME:-llm-lab} -n llm-observability \
	  port-forward svc/kps-grafana 3000:80

.PHONY: prom
prom: ## port-forward Prometheus to localhost:9091
	@echo "Prometheus -> http://localhost:9091/targets  (ctrl-c to stop)"
	@kubectl --context kind-$${CLUSTER_NAME:-llm-lab} -n llm-observability \
	  port-forward svc/kps-prometheus 9091:9090

.PHONY: ui
ui: ## open the active gateway's web UI (port-forward)
	@$(S)/ui.sh

.PHONY: status
status: ## what is running and what it costs
	@$(S)/status.sh

.PHONY: logs-vllm
logs-vllm: ## follow vLLM startup (slow on CPU)
	@kubectl --context kind-$${CLUSTER_NAME:-llm-lab} -n llm-serving logs -l app=vllm-cpu --tail=100 -f

.PHONY: logs-epp
logs-epp: ## follow the endpoint picker's routing decisions
	@kubectl --context kind-$${CLUSTER_NAME:-llm-lab} -n llm-serving logs -l app=primary-pool-epp --tail=100 -f

.PHONY: logs-gateway
logs-gateway: ## follow the active AI gateway
	@kubectl --context kind-$${CLUSTER_NAME:-llm-lab} -n llm-gateway logs --tail=100 -f --all-containers --prefix -l app.kubernetes.io/managed-by=Helm

.PHONY: bench
bench: ## compare gateway overhead: through ingress vs straight to the backend
	@$(S)/bench.sh

.PHONY: orphans
orphans: ## find kind clusters/registries left behind under EITHER runtime
	@$(S)/orphans.sh

.PHONY: down
down: ## delete the cluster, keep the built image
	@$(S)/down.sh

.PHONY: nuke
nuke: down ## delete the cluster AND the registry and cached state
	@source $(S)/lib.sh >/dev/null 2>&1; $${CONTAINER_CLI:-podman} rm -f $${REGISTRY_NAME:-kind-registry} >/dev/null 2>&1 || true
	@rm -rf .state
	@echo "removed registry and local state"
