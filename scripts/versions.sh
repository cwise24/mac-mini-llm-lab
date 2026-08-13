#!/usr/bin/env bash
# Compare pinned versions against what upstream currently ships.
#
# Every version in .env is a deliberate pin, but pins rot. This makes the drift
# visible instead of letting you discover it through a confusing install failure.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need curl; need jq

latest_gh() { # latest_gh owner/repo -> tag without leading v
  curl -fsS --max-time 10 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // empty' | sed 's/^v//'
}

row() { # row <label> <pinned> <latest>
  local label="$1" pinned="$2" latest="$3" mark="ok"
  [[ -z "${latest}" ]] && mark="?" || { [[ "${pinned}" != "${latest}" ]] && mark="DRIFT"; }
  printf '  %-26s pinned %-12s latest %-12s %s\n' "${label}" "${pinned}" "${latest:-unknown}" "${mark}"
}

log "checking pinned versions against upstream"
row "NGINX Gateway Fabric" "${NGF_VERSION}"              "$(latest_gh nginx/nginx-gateway-fabric)"
row "Envoy Gateway"        "${ENVOY_GATEWAY_VERSION#v}"  "$(latest_gh envoyproxy/gateway)"
row "Envoy AI Gateway"     "${ENVOY_AI_GATEWAY_VERSION#v}" "$(latest_gh envoyproxy/ai-gateway)"
row "Inference Extension"  "${GIE_VERSION#v}"            "$(latest_gh kubernetes-sigs/gateway-api-inference-extension)"
row "kind node image"      "${KIND_NODE_IMAGE##*:v}"     "$(latest_gh kubernetes/kubernetes)"
echo
warn "DRIFT is informational. Bump one component at a time and re-run 'make smoke'."
