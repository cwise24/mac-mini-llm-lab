#!/usr/bin/env bash
# Write a full diagnostic bundle into the repo so it can be read directly,
# instead of being copy-pasted into chat.
#
# Usage:  make capture            -- snapshot current state
#         make capture CMD="make gateway GW=litellm"   -- run a command and capture it
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT="${REPO_ROOT}/diagnostics.log"
: > "${OUT}"

sec() { printf '\n===== %s =====\n' "$1" >> "${OUT}"; }
run() { printf '\n$ %s\n' "$*" >> "${OUT}"; "$@" >> "${OUT}" 2>&1 || printf '[exit %s]\n' "$?" >> "${OUT}"; }

sec "when"
date >> "${OUT}"

if [[ -n "${CMD:-}" ]]; then
  sec "command: ${CMD}"
  printf '$ %s\n' "${CMD}" >> "${OUT}"
  bash -c "${CMD}" >> "${OUT}" 2>&1 || printf '[exit %s]\n' "$?" >> "${OUT}"
fi

sec "config"
run bash -c 'grep -vE "^\s*#|^\s*$" "'"${REPO_ROOT}"'/.env" 2>/dev/null'

sec "nodes"
run kctl get nodes -o wide
run kctl get nodes --show-labels

sec "all pods"
run kctl get pods -A -o wide

sec "not running"
run bash -c 'kubectl --context kind-'"${CLUSTER_NAME}"' get pods -A --field-selector=status.phase!=Running 2>/dev/null'

sec "serving tier"
run kctl -n llm-serving get all
run kctl -n llm-serving describe pods

sec "gateway tier"
run kctl -n llm-gateway get all
run kctl -n llm-gateway get gateway,httproute -o wide

sec "ingress tier"
run kctl -n nginx-gateway get all

sec "gateway api"
run kctl get gatewayclass
run kctl get inferencepool -A

sec "recent events"
run bash -c 'kubectl --context kind-'"${CLUSTER_NAME}"' get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -40'

sec "helm releases"
run helm list -A --kube-context "kind-${CLUSTER_NAME}"

sec "helm repos configured"
run helm repo list

sec "logs: vllm"
run bash -c 'kubectl --context kind-'"${CLUSTER_NAME}"' -n llm-serving logs -l app=vllm-cpu --tail=60 --all-containers 2>&1'

sec "logs: epp"
run bash -c 'kubectl --context kind-'"${CLUSTER_NAME}"' -n llm-serving logs -l app=primary-pool-epp --tail=30 2>&1'

sec "node capacity"
run kctl describe node

ok "wrote ${OUT}"
echo "   Tell Claude: \"read diagnostics.log\""
