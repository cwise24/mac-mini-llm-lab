#!/usr/bin/env bash
# Isolate the cost of each layer by timing the same request at three depths.
#
# The comparison is only meaningful with PROFILE=lite (mock backend), where the
# model is not the bottleneck. Against real vLLM on CPU the model dominates by
# two orders of magnitude and every gateway looks identical.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

N="${N:-20}"
MODEL="${MODEL:-mock-fast}"
BODY="{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}"

if [[ "${PROFILE}" != "lite" ]]; then
  warn "PROFILE=${PROFILE}: model latency will swamp gateway overhead. PROFILE=lite gives a clean signal."
fi

time_endpoint() {
  local label="$1" url="$2" total=0 t
  for _ in $(seq 1 "${N}"); do
    t="$(curl -o /dev/null -s -w '%{time_total}' --max-time 60 \
         -X POST "${url}" -H 'Content-Type: application/json' \
         -H "Authorization: Bearer sk-llm-lab-local" -d "${BODY}" || echo 0)"
    total="$(awk -v a="${total}" -v b="${t}" 'BEGIN{print a+b}')"
  done
  awk -v tot="${total}" -v n="${N}" -v l="${label}" \
    'BEGIN{printf "    %-34s %8.1f ms/req\n", l, (tot/n)*1000}'
}

log "timing ${N} requests per layer"
time_endpoint "NGF -> ${GATEWAY} -> backend" "http://localhost:8080/v1/chat/completions"

log "port-forwarding straight to the backend"
kctl -n llm-serving port-forward svc/mock-backend 18000:8000 >/dev/null 2>&1 &
pf=$!; sleep 2
time_endpoint "direct to backend (no proxies)" "http://localhost:18000/v1/chat/completions"
kill "${pf}" 2>/dev/null || true

echo
ok "difference is the combined NGF + AI gateway overhead"
