#!/usr/bin/env bash
# Open the active AI gateway's web UI, if it has one.
#
# Uses port-forward rather than the ingress so it works even when the NGF route
# is mid-swap, and so the UI is reachable on its own port without competing with
# inference traffic on :8080.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PORT="${UI_PORT:-8090}"

svc="$(kctl -n llm-gateway get svc ai-gateway -o jsonpath='{.metadata.labels.llm-lab\.io/gateway}' 2>/dev/null || true)"
[[ -n "${svc}" ]] || svc="${GATEWAY}"

case "${svc}" in
  litellm)
    # Trailing slash is REQUIRED. /ui alone does not load; see the redirect rule
    # in manifests/ingress/ngf/gateway.yaml.
    target="svc/litellm"; path="/ui/"
    note="login -> username: admin   password: sk-llm-lab-local" ;;
  bifrost)
    target="svc/bifrost"; path="/"
    note="no auth by default in this lab's config" ;;
  envoy)
    warn "Envoy AI Gateway has no web UI -- it is configured entirely through CRDs."
    echo
    echo "  Inspect its config instead:"
    echo "    kubectl get aigatewayroute,aiservicebackend -n llm-gateway -o yaml"
    echo "    kubectl get gateway,httproute -A"
    echo
    echo "  Envoy's own admin interface (config dump, stats, clusters):"
    echo "    kubectl -n envoy-gateway-system port-forward deploy/\$(kubectl -n envoy-gateway-system get deploy -o jsonpath='{.items[0].metadata.name}') 19000:19000"
    echo "    open http://localhost:19000"
    exit 0 ;;
  *)
    die "no active gateway found (GATEWAY=${GATEWAY}); run: make gateway GW=litellm" ;;
esac

kctl -n llm-gateway get "${target}" >/dev/null 2>&1 \
  || die "${target} not found in llm-gateway; is ${svc} installed?"

ok "${svc} UI -> http://localhost:${PORT}${path}"
[[ -n "${note}" ]] && log "${note}"
log "ctrl-c to stop"
kctl -n llm-gateway port-forward "${target}" "${PORT}:8080"
