#!/usr/bin/env bash
# Expose the NGF data plane on a FIXED NodePort that kind maps to localhost:8080.
#
# Why this is a script and not a static manifest:
#
# NGF 2.x provisions a data-plane Deployment and Service per Gateway, and the pod
# labels it uses are an implementation detail that has changed across releases. A
# hardcoded `selector:` in a manifest is therefore a guess that silently produces
# a Service with zero endpoints -- which looks like a networking problem and is
# not one.
#
# Instead: wait for NGF to provision its Service, read the selector it actually
# used, and clone it onto a NodePort Service with the fixed port kind expects.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GW_NAME="${GW_NAME:-llm-ingress}"
GW_NS="${GW_NS:-llm-gateway}"
NODE_PORT=30080

log "waiting for NGF to provision a data plane for Gateway/${GW_NAME}"
svc=""
for _ in $(seq 1 60); do
  # NGF names the provisioned Service after the Gateway; match on that, then fall
  # back to any Service in the namespace carrying the gateway-name label.
  svc="$(kctl -n "${GW_NS}" get svc "${GW_NAME}" -o name 2>/dev/null | cut -d/ -f2 || true)"
  if [[ -z "${svc}" ]]; then
    svc="$(kctl -n "${GW_NS}" get svc \
      -l gateway.networking.k8s.io/gateway-name="${GW_NAME}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  [[ -n "${svc}" ]] && break
  sleep 3
done

if [[ -z "${svc}" ]]; then
  warn "NGF has not provisioned a data-plane Service yet."
  warn "  check: kubectl -n ${GW_NS} describe gateway ${GW_NAME}"
  warn "  a Gateway stays unprovisioned if no GatewayClass matches, or if its"
  warn "  listeners are rejected. Re-run 'make up' once it is Programmed."
  exit 0
fi

ok "NGF provisioned Service/${svc}"

selector="$(kctl -n "${GW_NS}" get svc "${svc}" -o json | jq -c '.spec.selector')"
[[ "${selector}" == "null" || -z "${selector}" ]] && die "Service/${svc} has no selector to clone"
ok "discovered selector: ${selector}"

http_port="$(kctl -n "${GW_NS}" get svc "${svc}" \
  -o jsonpath='{.spec.ports[?(@.port==80)].targetPort}' 2>/dev/null || true)"
[[ -n "${http_port}" ]] || http_port=80

log "publishing NodePort ${NODE_PORT} -> localhost:8080"
python3 - "$selector" "$http_port" "$NODE_PORT" <<'PY' | kubectl --context "kind-${CLUSTER_NAME}" apply -f -
import json, sys
selector, target, nodeport = json.loads(sys.argv[1]), sys.argv[2], int(sys.argv[3])
try: target = int(target)
except ValueError: pass
print(json.dumps({
  "apiVersion": "v1", "kind": "Service",
  "metadata": {
    "name": "llm-ingress-nodeport", "namespace": "llm-gateway",
    "annotations": {
      "llm-lab.io/note": "selector cloned from the NGF-provisioned Service by scripts/ingress-nodeport.sh"
    },
  },
  "spec": {
    "type": "NodePort", "selector": selector,
    "ports": [{"name": "http", "port": 80, "targetPort": target, "nodePort": nodeport}],
  },
}))
PY

ok "ingress reachable at http://localhost:8080"
