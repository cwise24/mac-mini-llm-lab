#!/usr/bin/env bash
# Acquire a vLLM CPU image that actually runs on linux/arm64.
#
# HISTORY: this script used to compile vLLM from source by default. That was
# wrong. Building vLLM on Apple Silicon reliably OOMs -- setup.py bdist_wheel
# forks one C++ job per core, each peaking at multiple GB, against a podman VM
# that has ~10 GB total. It is also a known-broken path upstream:
#   https://github.com/vllm-project/vllm/issues/21714
#
# STRATEGY NOW, in order:
#   1. pull a prebuilt arm64 CPU image  (seconds, works)
#   2. verify it is really arm64 and really contains vLLM
#   3. mirror it into the local registry so cluster rebuilds are instant
#   4. source build ONLY on explicit request: METHOD=source ./build.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib.sh"

METHOD="${METHOD:-prebuilt}"
TAG="${VLLM_IMAGE}"

# Community-maintained, explicitly built with BF16 for Apple Silicon. There is no
# official vLLM arm64 CPU image; upstream publishes CPU wheels for x86_64.
CANDIDATES=(
  "${VLLM_UPSTREAM_IMAGE:-docker.io/mekayelanik/vllm-cpu:latest}"
  "ghcr.io/mekayelanik/vllm-cpu:latest"
  # Some ARM chips lack BF16; this variant falls back to FP32/FP16
  "docker.io/mekayelanik/vllm-cpu:arm64-no-bf16-latest"
)

need "${CONTAINER_CLI}"

is_arm64() {
  local ref="$1" out
  out="$(ctr manifest inspect "${ref}" 2>/dev/null)" || return 1
  grep -q 'arm64' <<<"${out}"
}

# Catches both "exec format error" (wrong arch) and images that merely bundle the
# wheel without an importable vllm package. Cheaper here than in a CrashLoop.
runs_ok() {
  local ref="$1"
  ctr run --rm --entrypoint "" "${ref}" \
    python3 -c 'import vllm; print(vllm.__version__)' 2>/dev/null
}

mirror_to_registry() {
  local src="$1"

  # Start the registry if it is not up. It is normally started by `make up`, but
  # build-vllm usually runs BEFORE the cluster exists, so ordering would otherwise
  # silently cost you a multi-GB re-pull on every cluster rebuild.
  if ! curl -fsS --max-time 3 "http://localhost:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
    log "local registry not up; starting it"
    "${REPO_ROOT}/scripts/registry.sh" || true
    sleep 2
  fi

  if ! curl -fsS --max-time 3 "http://localhost:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
    warn "local registry still unreachable on :${REGISTRY_PORT}"
    warn "falling back to the upstream ref: pods re-pull from the internet each rebuild"
    warn "  (recorded in .state/vllm-image.env, so backends will still work)"
    echo "VLLM_IMAGE=${src}" > "${STATE_DIR}/vllm-image.env"
    return 0
  fi
  log "mirroring into local registry as ${TAG}"
  ctr tag "${src}" "${TAG}"
  ctr push --tls-verify=false "${TAG}" 2>/dev/null || ctr push "${TAG}"
  echo "VLLM_IMAGE=${TAG}" > "${STATE_DIR}/vllm-image.env"
  ok "mirrored -> ${TAG}"
}

build_from_source() {
  warn "source build requested. This is the fragile path; read the warning above."

  local mem_mb mem_gb
  mem_mb="$(ctr machine inspect --format '{{.Resources.Memory}}' 2>/dev/null | head -1 || echo 0)"
  mem_gb=$(( ${mem_mb:-0} / 1024 ))
  if (( mem_gb < 16 )); then
    warn "VM has ${mem_gb} GB. vLLM's C++ compile needs ~16 GB even at MAX_JOBS=1."
    warn "  podman machine stop && podman machine set --memory 16384 && podman machine start"
    warn "  (raise it back down after the build)"
    [[ "${FORCE:-0}" == "1" ]] || die "refusing to start a build that will OOM (FORCE=1 to override)"
  fi

  local src="${STATE_DIR}/vllm-src"
  local ref="${VLLM_REF:-v0.11.0}"
  if [[ ! -d "${src}/.git" ]]; then
    log "cloning vllm @ ${ref}"
    # NOT --depth 1: Dockerfile.cpu bind-mounts .git and setup.py reads version tags
    git clone --branch "${ref}" https://github.com/vllm-project/vllm.git "${src}"
  fi

  log "building ${TAG} for linux/arm64 with MAX_JOBS=1 (expect 60-120 min)"
  # MAX_JOBS=1 is the whole point. The default is nproc, and each parallel C++
  # translation unit peaks at 2-4 GB, which is what produced ResourceExhausted.
  ctr build \
    --platform linux/arm64 \
    -f "${src}/docker/Dockerfile.cpu" \
    --target vllm-openai \
    --build-arg max_jobs=1 \
    --build-arg nvcc_threads=1 \
    --build-arg VLLM_CPU_DISABLE_AVX512=true \
    --memory 14g \
    -t "${TAG}" \
    "${src}"

  mirror_to_registry "${TAG}"
}

# ---------------------------------------------------------------- main
if [[ "${METHOD}" == "source" ]]; then
  build_from_source
  exit 0
fi

if ctr image inspect "${TAG}" >/dev/null 2>&1 && [[ "${FORCE:-0}" != "1" ]]; then
  ok "${TAG} already present locally (FORCE=1 to re-acquire)"
  exit 0
fi

log "looking for a prebuilt arm64 vLLM CPU image"
for cand in "${CANDIDATES[@]}"; do
  log "trying ${cand}"

  if ! is_arm64 "${cand}"; then
    warn "  no arm64 manifest, skipping"
    continue
  fi
  ok "  arm64 manifest present"

  if ! ctr pull --platform linux/arm64 "${cand}" >/dev/null 2>&1; then
    warn "  pull failed, skipping"
    continue
  fi
  ok "  pulled"

  if ver="$(runs_ok "${cand}")"; then
    ok "  vllm ${ver} imports cleanly"
  else
    warn "  image pulled but 'import vllm' failed, skipping"
    continue
  fi

  mirror_to_registry "${cand}"
  echo
  ok "vLLM CPU image ready. Next: make backends"
  exit 0
done

echo
warn "no prebuilt arm64 image worked."
warn "options, best first:"
warn "  1. skip vLLM entirely -- the lab is fully functional without it:"
warn "       make backends PROFILE=lite     (mock backends emit vLLM-shaped metrics,"
warn "                                       so the Endpoint Picker still works)"
warn "     plus your host Metal engine via host-bridge for real inference."
warn "  2. pin a specific working tag:  VLLM_UPSTREAM_IMAGE=... make build-vllm"
warn "  3. compile from source (slow, needs a 16 GB VM):  METHOD=source make build-vllm"
die "could not acquire a vLLM CPU image"
