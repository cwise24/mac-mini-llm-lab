#!/usr/bin/env bash
# Deploy model-serving backends according to PROFILE, plus the llm-d scheduler.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP="${STATE_DIR}/rendered"; mkdir -p "${TMP}"

deploy_host_bridge() {
  log "deploying host-bridge (Metal engine on the Mac)"
  export HOST_IP; HOST_IP="$(resolve_host_ip)"
  export HOST_PORT="${HOST_ENGINE_PORT}"
  ok "host reachable from cluster at ${HOST_IP}:${HOST_PORT}"

  render "${REPO_ROOT}/manifests/backends/host-bridge/nginx.conf.tmpl" "${TMP}/nginx.conf"
  kctl -n llm-serving create configmap host-bridge-conf \
    --from-file=default.conf="${TMP}/nginx.conf" \
    --dry-run=client -o yaml | kctl apply -f -

  sed "s|NGINX_IMAGE_PLACEHOLDER|${NGINX_IMAGE}|" \
    "${REPO_ROOT}/manifests/backends/host-bridge/deployment.yaml" | kctl apply -f -
  # Config is baked into the pod; restart so a changed host IP takes effect
  kctl -n llm-serving rollout restart deployment/host-bridge
  wait_rollout llm-serving deployment host-bridge 120s
}

deploy_mock() {
  log "deploying mock backend"
  kctl apply -f "${REPO_ROOT}/manifests/backends/mock/deployment.yaml"
  wait_rollout llm-serving deployment mock-backend 180s
}

# Check a nodeSelector can actually be satisfied before deploying against it.
# Otherwise the failure surfaces 15 minutes later as a rollout timeout, with the
# real cause buried in pod events.
assert_schedulable() {
  local key="$1" val="$2"
  if ! kctl get nodes -l "${key}=${val}" -o name 2>/dev/null | grep -q .; then
    warn "no node carries ${key}=${val}; pods would sit Pending forever"
    warn "fixing it now"
    for node in $(kctl get nodes -o jsonpath='{.items[*].metadata.name}'); do
      kctl label node "${node}" "${key}=${val}" --overwrite >/dev/null
    done
    ok "labelled"
  fi
}

# Warn when requests cannot fit, rather than letting a replica hang in Pending.
check_capacity() {
  local replicas="$1" per_gi="$2" alloc_ki total
  alloc_ki="$(kctl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' | tr -d 'Ki')"
  total=$(( replicas * per_gi ))
  local alloc_gi=$(( alloc_ki / 1024 / 1024 ))
  if (( total > alloc_gi - 2 )); then
    warn "vLLM wants ${total}Gi (${replicas} x ${per_gi}Gi) but the node allocates ${alloc_gi}Gi."
    warn "  Expect replicas to stay Pending on insufficient memory."
    warn "  Set VLLM_REPLICAS=1 in .env, or give the podman machine more RAM."
  fi
}

deploy_vllm() {
  log "deploying vLLM (CPU, arm64)"
  assert_schedulable llm-lab.io/pool inference
  check_capacity "${VLLM_REPLICAS}" 3
  kctl -n llm-serving create configmap vllm-cpu-conf \
    --from-literal=model="${VLLM_MODEL}" \
    --from-literal=servedName="${VLLM_SERVED_NAME}" \
    --from-literal=maxModelLen="${VLLM_MAX_MODEL_LEN}" \
    --dry-run=client -o yaml | kctl apply -f -

  sed "s|VLLM_IMAGE_PLACEHOLDER|${VLLM_IMAGE}|" \
    "${REPO_ROOT}/manifests/backends/vllm-cpu/deployment.yaml" \
    | kctl apply -f -
  kctl -n llm-serving scale deployment/vllm-cpu --replicas="${VLLM_REPLICAS}"
  warn "vLLM on CPU takes several minutes to load. Watch: make logs-vllm"
  wait_rollout llm-serving deployment vllm-cpu 900s
}

deploy_scheduler() {
  log "deploying llm-d scheduling plane (InferencePool + Endpoint Picker)"
  sed "s|EPP_IMAGE_PLACEHOLDER|${EPP_IMAGE}|" \
    "${REPO_ROOT}/manifests/scheduler/llm-d/inferencepool.yaml" | kctl apply -f -
  wait_rollout llm-serving deployment primary-pool-epp 180s
}

case "${PROFILE}" in
  lite)
    deploy_mock
    ;;
  standard)
    deploy_host_bridge
    deploy_vllm
    ;;
  full)
    deploy_host_bridge
    deploy_mock
    deploy_vllm
    deploy_scheduler
    ;;
  *) die "unknown PROFILE '${PROFILE}' (lite|standard|full)" ;;
esac

ok "backends ready (profile: ${PROFILE})"
kctl -n llm-serving get pods
