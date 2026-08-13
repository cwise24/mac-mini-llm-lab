#!/usr/bin/env bash
# Shared helpers. Sourced, not executed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STATE_DIR="${REPO_ROOT}/.state"
mkdir -p "${STATE_DIR}"

# Load config with ENVIRONMENT WINNING over the file, so `make backends PROFILE=full`
# actually overrides .env. A plain `source` would silently clobber the override.
load_env() {
  local f="$1" line k v
  [[ -f "${f}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "${line}" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    k="${k//[[:space:]]/}"
    [[ -n "${!k:-}" ]] || export "${k}=${v}"
  done < "${f}"
}
# Precedence, highest first:
#   1. the shell environment      (make backends PROFILE=full)
#   2. .state/vllm-image.env      (what build.sh actually resolved at runtime)
#   3. .env                       (your config)
#   4. .env.example               (defaults for anything omitted)
#
# Layer 2 exists because the vLLM image reference is DISCOVERED, not configured.
# If the local registry was unreachable, build.sh falls back to the upstream ref,
# and .env's localhost:5001 tag would otherwise send pods into ImagePullBackOff.
load_env "${STATE_DIR}/vllm-image.env"
load_env "${REPO_ROOT}/.env"
load_env "${REPO_ROOT}/.env.example"

# Message helpers are defined FIRST because detect_runtime() below calls die()
# when the configured runtime is invalid. Defining them after would turn a clear
# "CONTAINER_CLI must be docker or podman" into "die: command not found".
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ---------------------------------------------------------------- runtime
# Container runtime: docker or podman. One choice, everything else derived.
#
# Three settings must agree or the lab breaks in ways that look unrelated:
#   CONTAINER_CLI            which binary to shell out to
#   KIND_EXPERIMENTAL_PROVIDER  kind silently uses docker unless this says podman
#   HOST_INTERNAL_NAME       podman and docker expose the host under DIFFERENT names
#
# Letting a person set those independently guarantees someone eventually has
# CONTAINER_CLI=docker next to a stale KIND_EXPERIMENTAL_PROVIDER=podman, and
# then kind builds a cluster one tool cannot see. So only CONTAINER_CLI is
# configurable; the other two are computed from it, every time.
detect_runtime() {
  local want="${CONTAINER_CLI:-auto}"

  if [[ "${want}" == "auto" || -z "${want}" ]]; then
    # Prefer a runtime that is actually up, not merely installed.
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
      want=podman
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      want=docker
    elif command -v podman >/dev/null 2>&1; then
      want=podman
    elif command -v docker >/dev/null 2>&1; then
      want=docker
    else
      die "neither podman nor docker found. brew install podman  (or docker)"
    fi
  fi

  case "${want}" in
    podman)
      CONTAINER_CLI=podman
      export KIND_EXPERIMENTAL_PROVIDER=podman
      HOST_INTERNAL_NAME=host.containers.internal
      ;;
    docker)
      CONTAINER_CLI=docker
      # Must be EMPTY, not "docker" -- kind only recognises podman/nerdctl here
      # and any other non-empty value is an error.
      unset KIND_EXPERIMENTAL_PROVIDER
      HOST_INTERNAL_NAME=host.docker.internal
      # Older docker CLIs gate `docker manifest inspect` behind this.
      export DOCKER_CLI_EXPERIMENTAL=enabled
      ;;
    *) die "CONTAINER_CLI must be docker, podman, or auto (got: ${want})" ;;
  esac
  export CONTAINER_CLI HOST_INTERNAL_NAME
}
detect_runtime

# True when the runtime keeps its own Linux VM whose size is fixed at creation
# (podman machine). Docker Desktop is resized through its own settings UI.
runtime_uses_machine() { [[ "${CONTAINER_CLI}" == "podman" ]]; }


ctr()  { "${CONTAINER_CLI}" "$@"; }
kctl() { kubectl --context "kind-${CLUSTER_NAME}" "$@"; }

# Resolve an address a pod can use to reach macOS.
#
# podman differs from docker in two ways that matter:
#   1. the magic name is host.containers.internal, not host.docker.internal
#   2. on macOS the traffic goes through gvproxy, which parks the host at
#      192.168.127.254 on the podman machine's internal network
# Either way, pods use cluster DNS and never see that name, so we resolve it
# inside the node and bake the literal IP into the bridge config.
resolve_host_ip() {
  local node="${CLUSTER_NAME}-control-plane" ip=""

  ip="$(ctr exec "${node}" getent hosts "${HOST_INTERNAL_NAME}" 2>/dev/null \
        | awk '{print $1}' | head -1 || true)"

  if [[ -z "${ip}" ]]; then
    ip="$(ctr exec "${node}" sh -c "grep -m1 '${HOST_INTERNAL_NAME}' /etc/hosts" 2>/dev/null \
          | awk '{print $1}' || true)"
  fi

  # Last-resort fallback, and it is runtime-specific.
  if [[ -z "${ip}" ]]; then
    if runtime_uses_machine; then
      # podman machine routes host traffic through gvproxy, which parks the
      # macOS host at a fixed address on the VM's internal network.
      ip="192.168.127.254"
      warn "${HOST_INTERNAL_NAME} unresolved; assuming gvproxy host address ${ip}"
    else
      # Docker: the kind bridge gateway reaches the Docker VM, which forwards.
      ip="$(ctr network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
      [[ -n "${ip}" ]] && warn "${HOST_INTERNAL_NAME} unresolved; using bridge gateway ${ip}"
    fi
  fi

  [[ -n "${ip}" ]] || die "could not resolve a route from the cluster to the host"
  echo "${ip}"
}

wait_rollout() {
  local ns="$1" kind_="$2" name="$3" timeout="${4:-300s}"
  log "waiting for ${kind_}/${name} in ${ns} (timeout ${timeout})"
  kctl -n "${ns}" rollout status "${kind_}/${name}" --timeout="${timeout}"
}

render() { # render <template> <out> ; substitutes __VAR__ tokens from the environment
  local tpl="$1" out="$2"
  python3 - "$tpl" "$out" <<'PY'
import os,re,sys
tpl,out=sys.argv[1],sys.argv[2]
s=open(tpl).read()
s=re.sub(r'__([A-Z0-9_]+)__', lambda m: os.environ.get(m.group(1), m.group(0)), s)
open(out,'w').write(s)
PY
}

# Publish the swap contract: Service/ai-gateway in llm-gateway on :8080.
#
# The upstream name is DISCOVERED, never guessed. Envoy Gateway appends a hash to
# its data-plane Service, and Helm fullname templates vary by release name, so a
# hardcoded externalName is a coin flip.
publish_ai_gateway() { # publish_ai_gateway <namespace> <label-selector> [port]
  local ns="$1" sel="$2" port="${3:-8080}" svc=""
  for _ in $(seq 1 30); do
    svc="$(kctl -n "${ns}" get svc -l "${sel}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${svc}" ]] && break
    sleep 2
  done
  [[ -n "${svc}" ]] || die "could not find a Service in ${ns} matching '${sel}'"

  local real_port
  real_port="$(kctl -n "${ns}" get svc "${svc}" \
    -o jsonpath='{.spec.ports[?(@.port=='"${port}"')].port}' 2>/dev/null || true)"
  [[ -n "${real_port}" ]] || \
    real_port="$(kctl -n "${ns}" get svc "${svc}" -o jsonpath='{.spec.ports[0].port}')"

  ok "discovered upstream: ${svc}.${ns}:${real_port}"

  kctl apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ai-gateway
  namespace: llm-gateway
  labels:
    llm-lab.io/gateway: "${GATEWAY_LABEL:-unknown}"
spec:
  type: ExternalName
  externalName: ${svc}.${ns}.svc.cluster.local
  ports:
    - name: http
      port: 8080
      targetPort: ${real_port}
YAML
}

# Does the cluster exist? `kind get clusters` alone is not trustworthy here.
#
# Under the podman provider it can come back empty even when node containers are
# present -- a stopped node (podman machine restart), a rootful/rootless split, or
# a provider-detection hiccup all produce a false negative. The failure mode is
# nasty: the guard says "no cluster", create runs, and kind aborts with
# "node(s) already exist" without changing anything, so `make up` can never
# resume after a mid-run failure. Check the container labels as a second source.
cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" && return 0
  ctr ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
      --format '{{.Names}}' 2>/dev/null | grep -q . && return 0
  return 1
}

cluster_nodes() {
  ctr ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
      --format '{{.Names}}' 2>/dev/null || true
}

# Bring stopped node containers back and wait for the API server.
ensure_cluster_running() {
  local started=0 n
  while read -r n; do
    [[ -z "${n}" ]] && continue
    if [[ "$(ctr inspect -f '{{.State.Running}}' "${n}" 2>/dev/null || echo false)" != "true" ]]; then
      log "starting stopped node ${n}"
      ctr start "${n}" >/dev/null && started=1
    fi
  done < <(cluster_nodes)

  if (( started )); then
    log "waiting for the API server to come back"
    for _ in $(seq 1 60); do
      kctl get --raw=/readyz >/dev/null 2>&1 && { ok "API server ready"; return 0; }
      sleep 3
    done
    warn "API server did not become ready; try: make down && make up"
    return 1
  fi

  kctl get --raw=/readyz >/dev/null 2>&1 \
    || { warn "cluster exists but the API server is unreachable"; return 1; }
  return 0
}

# Helm against public OCI registries, isolated from local credential state.
#
# Symptom: `403: denied` fetching a chart that curl can pull anonymously.
#
# Mechanism (Helm 4 + ghcr.io): --registry-config only points helm at a different
# auth FILE. It does not stop the OCI client from resolving credentials through
# docker's credential helpers -- `credsStore` / `credHelpers` in
# ~/.docker/config.json, which on macOS pull from the Keychain. An expired ghcr
# entry there gets attached to the token request, and ghcr answers 403 instead of
# issuing an anonymous token. The credential never appears in any file you can
# grep, which is why the file-level bypass looked like it should work and didn't.
#
# So isolate DOCKER_CONFIG as well: an empty directory means no auths, no
# credsStore, no helpers, and the client falls back to a genuine anonymous pull.
#
# HELM_USE_HOST_AUTH=1 restores normal credential handling for private charts.
helm_oci() {
  if [[ "${HELM_USE_HOST_AUTH:-0}" == "1" ]]; then
    helm --kube-context "kind-${CLUSTER_NAME}" "$@"
    return
  fi
  local cfg="${STATE_DIR}/helm-anon-registry.json"
  local dcfg="${STATE_DIR}/anon-docker-config"
  echo '{"auths":{}}' > "${cfg}"
  mkdir -p "${dcfg}"; echo '{}' > "${dcfg}/config.json"

  DOCKER_CONFIG="${dcfg}" \
  HELM_REGISTRY_CONFIG="${cfg}" \
  helm --kube-context "kind-${CLUSTER_NAME}" --registry-config "${cfg}" "$@"
}

# Install a chart that is published as OCI, falling back to the chart source in
# the project's git repo.
#
# Rationale: this lab depends on four OCI charts (NGF, Envoy Gateway, Envoy AI
# Gateway CRDs and controller). A single broken helm OCI client therefore takes
# out the whole build. Every one of these projects also keeps its chart in-tree,
# so cloning the release tag and installing from the directory gets the identical
# chart with no registry client involved. Slower, and completely reliable.
#
#   helm_chart_install <release> <ns> <oci-ref> <version> <git-url> <tag> <subpath> [extra helm args...]
# HELM_CHART_METHOD_USED reports which path actually succeeded (oci|source).
# Callers that try several methods in a loop would otherwise report the method
# they *asked* for, not the one that worked -- "installed via oci" when the OCI
# pull 403'd and the source fallback did the work is an actively misleading
# thing to read while diagnosing a registry problem.
HELM_CHART_METHOD_USED=""

helm_chart_install() {
  local release="$1" ns="$2" oci="$3" version="$4" giturl="$5" tag="$6" subpath="$7"
  shift 7
  HELM_CHART_METHOD_USED=""

  if [[ "${CHART_INSTALL_METHOD:-auto}" != "source" ]]; then
    log "installing ${release} from ${oci} (${version})"
    if helm_oci upgrade --install "${release}" "${oci}" \
         --version "${version}" --namespace "${ns}" --create-namespace \
         "$@"; then
      ok "${release} installed from OCI"
      HELM_CHART_METHOD_USED=oci
      return 0
    fi
    warn "OCI install of ${release} failed; falling back to chart source"
    warn "  (diagnose the registry client with: make doctor-registry)"
  fi

  local src="${STATE_DIR}/charts/${release}"
  if [[ ! -d "${src}/.git" ]]; then
    log "cloning ${giturl} @ ${tag}"
    rm -rf "${src}" 2>/dev/null || true
    mkdir -p "$(dirname "${src}")"
    git clone --depth 1 --branch "${tag}" "${giturl}" "${src}" \
      || die "could not clone ${giturl} @ ${tag}"
  fi
  [[ -d "${src}/${subpath}" ]] || die "chart path not found: ${src}/${subpath}"

  log "installing ${release} from source tree ${subpath}"
  helm --kube-context "kind-${CLUSTER_NAME}" upgrade --install "${release}" \
    "${src}/${subpath}" --namespace "${ns}" --create-namespace "$@"
  HELM_CHART_METHOD_USED=source
  ok "${release} installed from source"
}
