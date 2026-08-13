#!/usr/bin/env bash
# Fails fast on the things that actually break this lab, before anything is built.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "preflight (runtime: ${CONTAINER_CLI})"
fail=0

for t in "${CONTAINER_CLI}" kind kubectl helm jq python3; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"
  else warn "missing: $t  (brew install $t)"; fail=1; fi
done

ctr info >/dev/null 2>&1 || { warn "${CONTAINER_CLI} not reachable -- is the machine started?"; fail=1; }

ok "host arch: $(uname -m)"
if [[ "$(uname -m)" == "arm64" ]]; then
  ok "Apple Silicon: in-cluster inference is CPU-only (no Metal passthrough into the podman VM)"
fi

if [[ "${CONTAINER_CLI}" == "podman" ]]; then
  # Rootless podman + kind needs cgroup v2 delegation that podman machine does not
  # set up by default. Symptom is kubelet failing on cpu/memory controllers.
  if ctr machine inspect --format '{{.Rootful}}' 2>/dev/null | grep -qi false; then
    warn "podman machine is ROOTLESS. kind is unreliable here."
    warn "  fix: podman machine stop && podman machine set --rootful && podman machine start"
    fail=1
  else
    ok "podman machine is rootful"
  fi

  mem_mb="$(ctr machine inspect --format '{{.Resources.Memory}}' 2>/dev/null | head -1 || echo 0)"
  cpus="$(ctr machine inspect --format '{{.Resources.CPUs}}' 2>/dev/null | head -1 || echo 0)"
  mem_gb=$(( ${mem_mb:-0} / 1024 ))
else
  mem_gb=$(( $(ctr info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
  cpus="$(ctr info --format '{{.NCPU}}')"
fi

ok "VM memory: ${mem_gb} GB   cpus: ${cpus}"

# These are measured floors, not estimates, and `full` is deliberately 9 not 10.
#
# The 16 GB Mac mini this lab targets gives its podman machine ~9.9 GB, which
# integer-divides to 9 here. A threshold of 10 therefore made `make bootstrap`
# and `make rebuild` fail on the exact hardware the lab is written for -- and
# fail at step one, before anything could be shown to work. The full profile
# (host-bridge + mocks + vLLM + EPP) has been run repeatedly at 9 GB with
# VLLM_REPLICAS=1; that last part is what makes it fit, so raise replicas only
# alongside VM memory.
case "${PROFILE}" in
  lite) need_gb=4 ;; standard) need_gb=8 ;; full) need_gb=9 ;; *) need_gb=8 ;;
esac
if (( mem_gb < need_gb )); then
  warn "profile '${PROFILE}' wants >= ${need_gb} GB, VM has ${mem_gb} GB."
  warn "  podman machine memory is fixed at init. To change it:"
  warn "    podman machine stop && podman machine set --memory $(((need_gb+1)*1024)) --cpus 6 && podman machine start"
  warn "  or drop to PROFILE=lite"
  fail=1
fi
if (( ${cpus:-0} < 4 )); then
  warn "give the VM >= 4 CPUs; vLLM on CPU is compute-bound"
  fail=1
fi

# .env drift.
#
# .env correctly takes precedence over .env.example, which means a key you copied
# months ago silently shadows an updated default -- exactly how a stale
# NGF_VERSION survives a repo update. Surface it rather than debugging an install.
if [[ -f "${REPO_ROOT}/.env" ]]; then
  drift=0
  while IFS= read -r k; do
    ex="$(grep -E "^${k}=" "${REPO_ROOT}/.env.example" | head -1 | cut -d= -f2-)"
    cur="$(grep -E "^${k}=" "${REPO_ROOT}/.env" | head -1 | cut -d= -f2-)"
    if [[ -n "${ex}" && -n "${cur}" && "${ex}" != "${cur}" ]]; then
      [[ ${drift} -eq 0 ]] && warn ".env differs from .env.example:"
      warn "    ${k}: yours='${cur}'  example='${ex}'"
      drift=1
    fi
  done < <(grep -oE '^[A-Z0-9_]+(?==)' -P "${REPO_ROOT}/.env.example" 2>/dev/null \
           || grep -oE '^[A-Z0-9_]+=' "${REPO_ROOT}/.env.example" | tr -d '=')

  # Keys added to the example after you created .env
  while IFS= read -r k; do
    if ! grep -qE "^${k}=" "${REPO_ROOT}/.env"; then
      warn "missing from your .env (will fall back to the example): ${k}"
    fi
  done < <(grep -oE '^[A-Z0-9_]+=' "${REPO_ROOT}/.env.example" | tr -d '=')

  [[ ${drift} -eq 0 ]] && ok ".env in sync with .env.example"
fi

# Stale registry credentials.
#
# An expired ghcr.io token in any auth store helm or podman reads causes a 403 on
# charts and images that are actually public. Cheaper to flag than to decode.
for authfile in \
  "${HOME}/.config/helm/registry/config.json" \
  "${HOME}/.docker/config.json" \
  "${HOME}/.config/containers/auth.json" \
  "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json"
do
  if [[ -f "${authfile}" ]] && grep -q 'ghcr\.io' "${authfile}" 2>/dev/null; then
    warn "ghcr.io credentials found in ${authfile}"
    warn "  if they are expired, public pulls fail with 403 denied."
    warn "  helm calls already force anonymous; for podman image pulls run:"
    warn "    podman logout ghcr.io"
  fi
done

# Host inference engine (Metal)
if curl -fsS --max-time 2 "http://localhost:${HOST_ENGINE_PORT}/v1/models" >/dev/null 2>&1; then
  ok "host engine responding on :${HOST_ENGINE_PORT}"
else
  warn "no host engine on :${HOST_ENGINE_PORT} -- host-bridge will have no upstream"
  warn "  Ollama: OLLAMA_HOST=0.0.0.0 ollama serve   (127.0.0.1 is NOT reachable from the cluster)"
fi

if (( fail == 0 )); then ok "preflight passed"; else die "preflight found blocking issues (above)"; fi
