#!/usr/bin/env bash
# Install kube-prometheus-stack plus vLLM's own Grafana dashboard.
#
# Opt-in on purpose: this is the heaviest thing in the lab (~1 GB trimmed, ~2 GB
# at chart defaults) and this node has repeatedly proven it has less headroom
# than the request numbers suggest. It is never part of `make bootstrap`.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=llm-observability
RELEASE=kps
CHART_VERSION="${KPS_CHART_VERSION:-88.3.0}"
DASH_URL="https://raw.githubusercontent.com/vllm-project/vllm/${VLLM_REF}/examples/online_serving/prometheus_grafana/grafana.json"
DASH_LOCAL="${STATE_DIR}/vllm-src/examples/online_serving/prometheus_grafana/grafana.json"
DASH="${STATE_DIR}/vllm-grafana.json"

cluster_exists || die "no cluster; run 'make up' first"

# --- headroom check ---------------------------------------------------------
# Show the budget BEFORE installing, because the failure mode when this node runs
# out is not a scheduling error -- it is the API server dropping mid-install,
# which looks like a chart problem and is not.
log "current node allocation"
alloc_ki="$(kctl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' | tr -d 'Ki')"
alloc_mi=$(( alloc_ki / 1024 ))
req_mi="$(kctl get pods -A -o json | python3 -c '
import sys, json, re
def mi(v):
    if not v: return 0
    m=re.match(r"^(\d+)(Mi|Gi|Ki|M|G)?$", str(v))
    if not m: return 0
    n=int(m.group(1)); u=m.group(2) or ""
    return {"Gi":n*1024,"Mi":n,"Ki":n//1024,"G":n*954,"M":n}.get(u,n//1048576)
t=0
for p in json.load(sys.stdin)["items"]:
    if p.get("status",{}).get("phase") not in ("Running","Pending"): continue
    for c in p["spec"]["containers"]:
        t += mi(c.get("resources",{}).get("requests",{}).get("memory"))
print(t)')"
free_mi=$(( alloc_mi - req_mi ))
printf '    allocatable %5s Mi\n    requested   %5s Mi\n    free        %5s Mi\n' "${alloc_mi}" "${req_mi}" "${free_mi}"

# Trimmed stack requests ~600Mi and peaks higher while Prometheus builds its WAL.
if (( free_mi < 1600 )); then
  warn "under 1600 Mi free. The stack requests ~1090 Mi and peaks above that."
  warn "Free memory first, most effective first:"
  warn "    kubectl -n llm-serving scale deploy/vllm-cpu --replicas=0     (~3 Gi)"
  warn "    LITELLM_WITH_DB=false make gateway GW=litellm                 (~450 Mi)"
  warn "    kubectl -n llm-serving scale deploy/mock-backend --replicas=0 (~64 Mi)"
  [[ "${FORCE:-0}" == "1" ]] || die "refusing to install (FORCE=1 to override)"
  warn "FORCE=1 set; continuing"
fi

# --- vLLM dashboard ---------------------------------------------------------
# Prefer the copy in the local vllm checkout; fall back to fetching it.
if [[ -f "${DASH_LOCAL}" ]]; then
  cp "${DASH_LOCAL}" "${DASH}"; ok "dashboard from local vllm checkout"
elif curl -fsS --max-time 30 "${DASH_URL}" -o "${DASH}"; then
  ok "dashboard fetched from vllm ${VLLM_REF}"
else
  warn "could not obtain vLLM's grafana.json; installing without it"
  DASH=""
fi

# --- install ----------------------------------------------------------------
kctl create namespace "${NS}" --dry-run=client -o yaml | kctl apply -f - >/dev/null

log "adding prometheus-community repo"
# Scoped to this repo only: a bare `helm repo update` fails if ANY repo on the
# machine is unreachable.
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts \
  --force-update >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null 2>&1 || warn "repo refresh failed; using cached index"

log "installing kube-prometheus-stack ${CHART_VERSION} (several minutes)"
helm --kube-context "kind-${CLUSTER_NAME}" upgrade --install "${RELEASE}" \
  prometheus-community/kube-prometheus-stack \
  --version "${CHART_VERSION}" \
  --namespace "${NS}" --create-namespace \
  -f "${REPO_ROOT}/manifests/observability/values.yaml" \
  --wait --timeout 10m

log "registering vLLM + endpoint-picker scrape targets"
kctl apply -f "${REPO_ROOT}/manifests/observability/podmonitor-vllm.yaml"

if [[ -n "${DASH}" ]]; then
  log "importing the vLLM dashboard"
  # The label is what Grafana's sidecar watches for; without it the ConfigMap is
  # just a ConfigMap.
  kctl -n "${NS}" create configmap vllm-dashboard \
    --from-file=vllm.json="${DASH}" \
    --dry-run=client -o yaml \
    | kctl label -f - --local -o yaml grafana_dashboard=1 \
    | kctl apply -f -
fi

echo
ok "observability installed"
echo

# Is NodePort 30090 actually published on the host?
#
# kind fixes extraPortMappings at CLUSTER CREATION. A cluster built before the
# mapping existed in cluster/kind-config.yaml cannot gain it later, and the
# symptom is indistinguishable from a broken Service: connection refused on the
# host while pods, Service and endpoints are all perfectly healthy. Check the
# runtime rather than trusting the config file.
if ctr port "${CLUSTER_NAME}-control-plane" 2>/dev/null | grep -q "30090"; then
  echo "  Grafana:     http://localhost:9090     login: admin / llm-lab"
  echo "               Dashboards -> vLLM"
else
  warn "NodePort 30090 is NOT published by this cluster."
  warn "  cluster/kind-config.yaml maps 30090 -> 9090, but kind applies that only"
  warn "  at creation, so this cluster predates it. Either:"
  warn "     make grafana        port-forward, works now"
  warn "     make rebuild        recreate with the mapping (destroys the cluster)"
  echo
  echo "  Grafana:     make grafana   ->  http://localhost:3000   admin / llm-lab"
  echo "               Dashboards -> vLLM"
fi
echo "  Prometheus:  make prom     (port-forward to :9091)"
echo
echo "  Verify targets are UP before trusting an empty graph:"
echo "    make prom   then open http://localhost:9091/targets"
echo
warn "empty vLLM panels usually mean no traffic, not a broken scrape --"
warn "run 'make smoke' to generate some, then refresh."
