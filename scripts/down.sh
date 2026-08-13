#!/usr/bin/env bash
# Tear down the cluster. The registry is deliberately LEFT RUNNING so the
# expensive vLLM image survives -- `make nuke` removes it too.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if cluster_exists; then
  log "deleting cluster ${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}" || true

  # kind delete is a no-op for nodes it cannot see -- the same false negative that
  # breaks the create path. Sweep any survivors by label so the next `make up`
  # does not hit "node(s) already exist".
  while read -r n; do
    [[ -z "${n}" ]] && continue
    warn "removing orphaned node container ${n}"
    ctr rm -f "${n}" >/dev/null 2>&1 || true
  done < <(cluster_nodes)

  ok "cluster deleted (registry ${REGISTRY_NAME} kept; 'make nuke' to remove)"
else
  ok "cluster ${CLUSTER_NAME} not present"
fi
