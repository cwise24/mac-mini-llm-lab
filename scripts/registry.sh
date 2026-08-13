#!/usr/bin/env bash
# Local image registry wired into the kind node via containerd certs.d, so the
# expensive vLLM CPU image survives cluster rebuilds.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "$(ctr inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || echo false)" != "true" ]]; then
  log "starting registry ${REGISTRY_NAME} on :${REGISTRY_PORT}"
  ctr rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
  ctr run -d --restart=always \
    -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --name "${REGISTRY_NAME}" docker.io/library/registry:2 >/dev/null
else
  ok "registry already running"
fi

node="${CLUSTER_NAME}-control-plane"
if ctr inspect "${node}" >/dev/null 2>&1; then
  dir="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
  ctr exec "${node}" mkdir -p "${dir}"
  ctr exec -i "${node}" sh -c "cat > ${dir}/hosts.toml" <<HOSTS
[host."http://${REGISTRY_NAME}:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
HOSTS
  ctr network connect kind "${REGISTRY_NAME}" 2>/dev/null || true
  ok "node wired to registry"
else
  warn "cluster node not up yet; re-run after 'make up'"
fi
