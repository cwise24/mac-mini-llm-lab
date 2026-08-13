#!/usr/bin/env bash
# Install exactly one AI gateway and point NGF at it.
#
# Each overlay must end with a Service named `ai-gateway` in llm-gateway on :8080.
# That is the entire contract. NGF's HTTPRoute is never edited.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET="${1:-${GATEWAY}}"
TMP="${STATE_DIR}/rendered"; mkdir -p "${TMP}"
HELM=(helm --kube-context "kind-${CLUSTER_NAME}")
# OCI charts go through helm_oci() so stale registry credentials cannot break a
# public pull -- see the note in lib.sh.

# Remove an object ONLY if Helm does not already own it.
#
# Helm refuses to adopt a pre-existing object that lacks its ownership metadata:
#   Secret "litellm-masterkey" exists and cannot be imported into the current
#   release: invalid ownership metadata; missing key "app.kubernetes.io/managed-by"
#
# That is fatal and sticky: once such an orphan exists -- left by an older
# revision of this repo that created it with kubectl, or by an install that died
# between creating resources and recording a release -- every subsequent
# `make gateway GW=litellm` fails identically, and `make rebuild` cannot heal it
# because nothing ever removes the object. Deleting only unowned copies is safe:
# anything Helm owns is left to Helm's own uninstall above.
delete_if_unowned() { # delete_if_unowned <ns> <kind/name>
  local ns="$1" ref="$2" owner
  owner="$(kctl -n "${ns}" get "${ref}" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  [[ -z "${owner}" ]] || return 0          # Helm-owned (or someone else's): leave it
  kctl -n "${ns}" get "${ref}" >/dev/null 2>&1 || return 0
  warn "removing orphaned ${ref} (no Helm ownership metadata; would block install)"
  kctl -n "${ns}" delete "${ref}" --ignore-not-found
}

uninstall_all() {
  log "removing any previously active AI gateway"

  # ORDER MATTERS: custom resources first, controllers second.
  #
  # Envoy AI Gateway's CRs are applied with kubectl, so no Helm release owns them
  # and `helm uninstall aieg` leaves every one behind. They also carry finalizers
  # that only the AI Gateway controller can clear -- so deleting them AFTER
  # uninstalling that controller blocks forever on a finalizer nobody is left to
  # remove, and `make gateway` hangs with no output rather than failing.
  #
  # Swept from BOTH namespaces because these objects moved between llm-gateway
  # and llm-serving (see the namespace note in routes.yaml). A copy stranded in
  # the old namespace still attaches to the same Gateway and still generates its
  # own HTTPRoute, so the Gateway would serve a stale rule alongside the new one.
  #
  # --timeout is a backstop: if a finalizer is wedged anyway (controller already
  # crashed, say), time out and strip it rather than hanging the whole build.
  local ns obj
  for ns in llm-gateway llm-serving; do
    for obj in aigatewayroute/model-router \
               aiservicebackend/vllm-cpu-backend aiservicebackend/host-metal-backend \
               backend.gateway.envoyproxy.io/vllm-cpu-be \
               backend.gateway.envoyproxy.io/host-metal-be; do
      kctl -n "${ns}" get "${obj}" >/dev/null 2>&1 || continue
      if ! kctl -n "${ns}" delete "${obj}" --timeout=30s >/dev/null 2>&1; then
        warn "${ns}/${obj} did not delete cleanly; clearing finalizers"
        kctl -n "${ns}" patch "${obj}" --type=merge \
          -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        kctl -n "${ns}" delete "${obj}" --ignore-not-found --timeout=30s >/dev/null 2>&1 || true
      fi
    done
  done

  "${HELM[@]}" uninstall litellm -n llm-gateway            2>/dev/null || true
  "${HELM[@]}" uninstall bifrost  -n llm-gateway            2>/dev/null || true
  "${HELM[@]}" uninstall aieg     -n envoy-ai-gateway-system 2>/dev/null || true
  "${HELM[@]}" uninstall eg       -n envoy-gateway-system    2>/dev/null || true
  kctl delete svc ai-gateway -n llm-gateway --ignore-not-found
  kctl delete -f "${REPO_ROOT}/manifests/ingress/ngf/httproute-direct.yaml" --ignore-not-found 2>/dev/null || true

  # Charts generate these from values, so an unowned copy is always a leftover.
  delete_if_unowned llm-gateway secret/litellm-masterkey
  delete_if_unowned llm-gateway secret/bifrost
}

install_envoy() {
  # Envoy Gateway and AI Gateway are OCI charts (docker.io) and so share the
  # Helm-4 credential-resolution failure mode described in lib.sh. LiteLLM and
  # Bifrost use classic HTTP chart repos and are immune -- if this path is
  # blocked on your machine, GW=litellm is a working alternative.
  # Envoy Gateway's chart bundles its own copy of the Gateway API CRDs, and we
  # must not let it install them.
  #
  # Two reasons. First, ownership: Helm 4 applies crds/ server-side, and ours
  # were applied by kubectl, so every shared CRD fails with
  #   Apply failed with 3 conflicts: conflicts with "kubectl":
  #   .spec.versions, .metadata.annotations...
  # which aborts the whole install. Second and more important, the bundled copy
  # is the STANDARD channel -- letting it win would silently downgrade the
  # experimental CRDs that GATEWAY=none depends on, breaking a different mode
  # entirely and only when you next switched to it.
  #
  # --skip-crds suppresses the whole crds/ directory, including the 8 CRDs that
  # genuinely belong to Envoy Gateway (gateway.envoyproxy.io: EnvoyProxy,
  # SecurityPolicy, ...), so those are applied here by hand. Gateway API CRDs
  # stay owned by up.sh, pinned to NGF's version. Clone first so the directory
  # is present even when the OCI path would otherwise have been used.
  local eg_src="${STATE_DIR}/charts/eg"
  if [[ ! -d "${eg_src}/.git" ]]; then
    log "cloning envoyproxy/gateway @ ${ENVOY_GATEWAY_VERSION} for its CRDs"
    rm -rf "${eg_src}" 2>/dev/null || true
    git clone --depth 1 --branch "${ENVOY_GATEWAY_VERSION}" \
      https://github.com/envoyproxy/gateway.git "${eg_src}" \
      || die "could not clone envoyproxy/gateway @ ${ENVOY_GATEWAY_VERSION}"
  fi

  log "applying Envoy Gateway's own CRDs (Gateway API CRDs deliberately excluded)"
  kctl apply --server-side --force-conflicts \
    -f "${eg_src}/charts/gateway-helm/crds/generated/"

  log "installing Envoy Gateway ${ENVOY_GATEWAY_VERSION}"
  helm_chart_install eg envoy-gateway-system \
    oci://docker.io/envoyproxy/gateway-helm "${ENVOY_GATEWAY_VERSION}" \
    https://github.com/envoyproxy/gateway.git "${ENVOY_GATEWAY_VERSION}" \
    charts/gateway-helm \
    -f "${REPO_ROOT}/manifests/gateways/envoy-ai-gateway/values.yaml" \
    --skip-crds --wait --timeout 5m

  log "installing Envoy AI Gateway ${ENVOY_AI_GATEWAY_VERSION}"
  helm_chart_install aieg-crd envoy-ai-gateway-system \
    oci://docker.io/envoyproxy/ai-gateway-crds-helm "${ENVOY_AI_GATEWAY_VERSION}" \
    https://github.com/envoyproxy/ai-gateway.git "${ENVOY_AI_GATEWAY_VERSION}" \
    manifests/charts/ai-gateway-crds-helm \
    --take-ownership --wait

  helm_chart_install aieg envoy-ai-gateway-system \
    oci://docker.io/envoyproxy/ai-gateway-helm "${ENVOY_AI_GATEWAY_VERSION}" \
    https://github.com/envoyproxy/ai-gateway.git "${ENVOY_AI_GATEWAY_VERSION}" \
    manifests/charts/ai-gateway-helm \
    --wait --timeout 5m

  render "${REPO_ROOT}/manifests/gateways/envoy-ai-gateway/routes.yaml" "${TMP}/envoy-routes.yaml"
  kctl apply -f "${TMP}/envoy-routes.yaml"

  # Envoy Gateway names the data-plane Service envoy-<ns>-<gw>-<hash>. The hash is
  # not predictable, so find it by owner label rather than by name.
  GATEWAY_LABEL=envoy publish_ai_gateway envoy-gateway-system \
    "gateway.envoyproxy.io/owning-gateway-name=envoy-ai-gateway" 8080
}

install_litellm() {
  log "installing LiteLLM (chart ${LITELLM_CHART_VERSION})"
  render "${REPO_ROOT}/manifests/gateways/litellm/values.yaml" "${TMP}/litellm-values.yaml"

  # No classic repo (berriai.github.io/litellm 404s) and no OCI package.
  # The chart only exists in-tree at helm/litellm-helm.
  CHART_INSTALL_METHOD=source helm_chart_install litellm llm-gateway \
    "" "${LITELLM_CHART_VERSION}" \
    https://github.com/BerriAI/litellm.git "${LITELLM_CHART_REF}" \
    helm/litellm-helm \
    -f "${TMP}/litellm-values.yaml" --wait --timeout 6m

  GATEWAY_LABEL=litellm publish_ai_gateway llm-gateway \
    "app.kubernetes.io/instance=litellm" 8080
}

install_bifrost() {
  log "installing Bifrost (chart ${BIFROST_CHART_VERSION})"
  render "${REPO_ROOT}/manifests/gateways/bifrost/values.yaml" "${TMP}/bifrost-values.yaml"

  # Same story: chart exists only at helm-charts/bifrost on the dev branch.
  CHART_INSTALL_METHOD=source helm_chart_install bifrost llm-gateway \
    "" "${BIFROST_CHART_VERSION}" \
    https://github.com/maximhq/bifrost.git "${BIFROST_CHART_REF}" \
    helm-charts/bifrost \
    -f "${TMP}/bifrost-values.yaml" --wait --timeout 6m

  GATEWAY_LABEL=bifrost publish_ai_gateway llm-gateway \
    "app.kubernetes.io/instance=bifrost" 8080
}

install_none() {
  log "no AI gateway: NGF -> InferencePool directly"
  kctl apply -f "${REPO_ROOT}/manifests/ingress/ngf/httproute-direct.yaml"
  kctl delete httproute ai-gateway-route -n llm-gateway --ignore-not-found
}

oci_hint() {
  warn "an OCI chart pull failed. This is usually the Helm 4 + credential-helper"
  warn "issue, not a real permissions problem. Options:"
  warn "  make doctor-registry     diagnose"
  warn "  docker logout ghcr.io    clear the stale keychain entry"
  warn "  make gateway GW=litellm  uses a classic chart repo, unaffected"
}
trap 'oci_hint' ERR

uninstall_all
case "${TARGET}" in
  envoy)   install_envoy   ;;
  litellm) install_litellm ;;
  bifrost) install_bifrost ;;
  none)    install_none    ;;
  *) die "unknown gateway '${TARGET}' (envoy|litellm|bifrost|none)" ;;
esac

if [[ "${TARGET}" != "none" ]]; then
  kctl apply -f "${REPO_ROOT}/manifests/ingress/ngf/gateway.yaml"
fi

# Do not report success until the ingress actually serves this gateway.
#
# Every helm --wait above only proves the PODS are ready. The data path needs
# more than that: NGF has to re-resolve the ai-gateway ExternalName, Envoy
# Gateway has to push new xDS to its data plane, and the AI Gateway controller
# has to translate the AIGatewayRoute. That takes a few more seconds, during
# which requests still 404/500.
#
# Without this gate `make gateway GW=x && make smoke` is a race, and it loses
# often enough to matter -- swapping all four in a loop produced spurious
# "ingress reachable" and "streaming" failures on three of them, each of which
# passed when re-run by hand moments later. That failure mode is far worse than a
# slow target: it makes the smoke test look flaky and hides real regressions.
log "waiting for the ingress to serve the new gateway"
ready=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "http://localhost:8080/v1/models" \
       -H "Authorization: Bearer ${SMOKE_KEY:-sk-llm-lab-local}" >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 3
done
if (( ready )); then
  ok "ingress serving"
else
  warn "ingress did not start serving within 180s"
  warn "  check: kubectl -n llm-gateway get httproute -o yaml | grep -A5 conditions"
  die "gateway '${TARGET}' installed but is not reachable through the ingress"
fi

# Print endpoints that actually resolve.
#
# This used to say "-> http://localhost:8080/v1", which reads like a link but is
# a path PREFIX, not a route. Opening it returns "unsupported path: /v1" from the
# gateway -- correct behaviour that looks exactly like a broken deployment.
echo
ok "active AI gateway: ${TARGET}"
echo
echo "  Browse (GET, renders in a browser):"
echo "    http://localhost:8080/v1/models"
echo
echo "  Inference (POST):"
cat <<'CURL'
    curl http://localhost:8080/v1/chat/completions       -H 'Content-Type: application/json'       -H 'Authorization: Bearer sk-llm-lab-local'       -d '{"model":"MODEL","messages":[{"role":"user","content":"hello"}]}'
CURL
echo
case "${TARGET}" in
  litellm) echo "  Web UI:  make ui   ->  http://localhost:8090/ui  (key: sk-llm-lab-local)" ;;
  bifrost) echo "  Web UI:  make ui   ->  http://localhost:8090/" ;;
  envoy)   echo "  Web UI:  none -- Envoy AI Gateway is configured through CRDs."
           echo "           Inspect:  kubectl get aigatewayroute,aiservicebackend -n llm-gateway" ;;
  none)    echo "  Web UI:  none -- NGF routes straight to the InferencePool." ;;
esac
echo
echo "  Verify:  make smoke"
