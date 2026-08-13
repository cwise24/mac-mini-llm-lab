#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
