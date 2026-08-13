#!/usr/bin/env bash
# End-to-end check. Same assertions pass whichever AI gateway is active --
# that is the point of the swappable design.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE="${BASE:-http://localhost:8080}"
KEY="${KEY:-sk-llm-lab-local}"
pass=0; fail=0
FAILED=()

# Record the NAME of every failure, not just a tally.
#
# The old summary said "1 check(s) failed" and nothing else, so identifying which
# one meant scrolling back through inference output that can run to hundreds of
# lines. When the summary is the only thing a person copies, the summary has to
# carry the diagnosis.
note_pass() { ok "$1"; pass=$((pass+1)); }
note_fail() { warn "FAIL: $1"; fail=$((fail+1)); FAILED+=("$1"); }

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then note_pass "${name}"; else note_fail "${name}"; fi
}

# Report the gateway that is actually SERVING, not the one .env asks for.
#
# `make smoke` is normally run on its own, so ${GATEWAY} is whatever .env says --
# which after `make gateway GW=litellm` is stale, and the run then cheerfully
# reports "gateway: envoy" while testing LiteLLM. In a loop over all four modes
# that turns a pass/fail table into a misleading one. publish_ai_gateway() stamps
# the truth onto Service/ai-gateway as a label, so read it back from the cluster.
# GATEWAY=none publishes no such Service, hence the fallback.
active_gateway() {
  local g
  g="$(kctl -n llm-gateway get svc ai-gateway \
        -o jsonpath='{.metadata.labels.llm-lab\.io/gateway}' 2>/dev/null || true)"
  if [[ -z "${g}" ]]; then
    if kctl -n llm-serving get httproute inferencepool-direct >/dev/null 2>&1; then
      g="none"
    else
      g="${GATEWAY:-unknown} (declared; no ai-gateway Service found)"
    fi
  fi
  echo "${g}"
}

log "smoke test against ${BASE} (gateway: $(active_gateway), profile: ${PROFILE})"

check "ingress reachable" \
  curl -fsS --max-time 10 "${BASE}/v1/models" -H "Authorization: Bearer ${KEY}"

log "advertised models:"
curl -fsS --max-time 10 "${BASE}/v1/models" -H "Authorization: Bearer ${KEY}" \
  | jq -r '.data[].id' 2>/dev/null | sed 's/^/    /' || warn "  could not list models"

case "${PROFILE}" in
  lite) MODEL="mock-fast" ;;
  *)    MODEL="${VLLM_SERVED_NAME}" ;;
esac

log "chat completion against '${MODEL}' (CPU inference is slow; allow ~2 min)"
resp="$(curl -fsS --max-time 300 "${BASE}/v1/chat/completions" \
  -H "Content-Type: application/json" -H "Authorization: Bearer ${KEY}" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":16}" \
  2>/dev/null || true)"

# Require NON-EMPTY content, not merely a present field.
#
# `jq -e` only fails on null/false, so an empty string counts as success. A
# gateway that returns a well-formed completion with content:"" therefore scored
# a green "chat completion" while actually generating nothing -- the single most
# misleading result this test can produce, because it certifies exactly the thing
# it failed to check.
content="$(jq -r '.choices[0].message.content // empty' <<<"${resp}" 2>/dev/null || true)"
if [[ -n "${content}" ]]; then
  note_pass "chat completion"
  printf '    reply: %s\n' "$(head -c 200 <<<"${content}")"
else
  note_fail "chat completion (no content returned)"
  printf '    raw: %s\n' "$(head -c 300 <<<"${resp}")"
fi

log "streaming (SSE must not be buffered by NGF or the bridge)"
# Collect first, match second -- do NOT pipe curl straight into grep here.
#
# lib.sh sets `set -o pipefail`, and `grep -q` exits the instant it matches. That
# closes the pipe, curl dies of SIGPIPE, and pipefail then reports the whole
# pipeline as failed even though the stream was perfect. The result is a
# streaming check that fails precisely when streaming WORKS -- which is a nasty
# thing to debug, because reproducing the curl by hand always succeeds.
stream_out="$(curl -fsS --max-time 300 -N "${BASE}/v1/chat/completions" \
     -H "Content-Type: application/json" -H "Authorization: Bearer ${KEY}" \
     -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"count to three\"}],\"max_tokens\":24,\"stream\":true}" \
     2>/dev/null || true)"
if grep -q '^data:' <<<"${stream_out}"; then
  note_pass "streaming"
else
  note_fail "streaming"
fi

if [[ "${PROFILE}" == "full" ]]; then
  log "endpoint picker health"

  # This used to be `check "EPP ready" kubectl get deploy -o jsonpath=...`, which
  # cannot fail: kubectl exits 0 whenever the Deployment exists, and an empty
  # jsonpath result is still a successful command. Zero ready replicas scored a
  # green tick. Compare the value instead of trusting the exit code.
  ready="$(kctl -n llm-serving get deploy primary-pool-epp \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ "${ready:-0}" -ge 1 ]] 2>/dev/null; then
    note_pass "EPP ready (${ready} replica)"
  else
    note_fail "EPP ready (readyReplicas=${ready:-none})"
    kctl -n llm-serving get pods -l app=primary-pool-epp 2>/dev/null | sed 's/^/    /' || true
    kctl -n llm-serving logs -l app=primary-pool-epp --tail=15 2>/dev/null | sed 's/^/    /' || true
  fi

  # An InferencePool with no endpoints routes nowhere. `get -o wide` shows only
  # NAME and AGE, which tells you nothing about whether the selector matched, so
  # count the pods it should be selecting.
  sel_pods="$(kctl -n llm-serving get pods -l llm-lab.io/inference-pool=primary \
               --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${sel_pods:-0}" -ge 1 ]]; then
    note_pass "InferencePool has ${sel_pods} running backend pod(s)"
  else
    note_fail "InferencePool selects no running pods (label llm-lab.io/inference-pool=primary)"
  fi

  log "InferencePool:"
  kctl -n llm-serving get inferencepool primary-pool -o wide 2>/dev/null | sed 's/^/    /' || true
fi

echo
if (( fail == 0 )); then
  ok "smoke passed (${pass} checks)"
else
  warn "${fail} check(s) failed, ${pass} passed:"
  for f in "${FAILED[@]}"; do warn "    - ${f}"; done
  echo
  warn "next: make capture   (writes full diagnostics to diagnostics.log)"
  exit 1
fi
