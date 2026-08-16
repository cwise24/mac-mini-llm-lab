#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo; log "runtime"
printf '    %-14s %s\n' "engine" "${CONTAINER_CLI}"
printf '    %-14s %s\n' "kind provider" "${KIND_EXPERIMENTAL_PROVIDER:-docker (default)}"
printf '    %-14s %s\n' "host name" "${HOST_INTERNAL_NAME}"

echo; log "cluster"
kctl get nodes -o wide 2>/dev/null || { warn "cluster not reachable"; exit 0; }

echo; log "serving tier"
kctl -n llm-serving get pods,svc 2>/dev/null

echo; log "gateway tier"
kctl -n llm-gateway get pods,svc,gateway,httproute 2>/dev/null

echo; log "ingress tier"
kctl -n nginx-gateway get pods 2>/dev/null

echo; log "inference pool"
kctl -n llm-serving get inferencepool 2>/dev/null || echo "    (not deployed; PROFILE=full enables it)"

echo; log "memory pressure"
kctl top pods -A --sort-by=memory 2>/dev/null | head -15 || echo "    (metrics-server not installed)"
echo
