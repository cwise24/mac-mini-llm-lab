#!/usr/bin/env bash
# Remove the observability stack and reclaim ~1 GB.
#
# The operator's CRDs are deliberately NOT deleted: helm does not remove CRDs on
# uninstall, and deleting them would take every PodMonitor and ServiceMonitor in
# the cluster with them. Reinstalling is faster with them in place.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

helm --kube-context "kind-${CLUSTER_NAME}" uninstall kps -n llm-observability 2>/dev/null \
  || warn "release 'kps' not found"
kctl delete -f "${REPO_ROOT}/manifests/observability/podmonitor-vllm.yaml" --ignore-not-found
kctl -n llm-observability delete configmap vllm-dashboard --ignore-not-found
ok "observability removed (CRDs kept; delete them by hand if you really want them gone)"
