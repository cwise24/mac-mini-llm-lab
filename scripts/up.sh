#!/usr/bin/env bash
# Create the cluster and install the always-on tiers: CRDs + NGF ingress.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# up.sh is idempotent and resumable: every step below is `helm upgrade --install`
# or a server-side apply, so re-running after a mid-run failure is the intended
# recovery path. RECREATE=1 forces a clean slate instead.
if [[ "${RECREATE:-0}" == "1" ]] && cluster_exists; then
  warn "RECREATE=1: deleting the existing cluster first"
  kind delete cluster --name "${CLUSTER_NAME}" || true
fi

if cluster_exists; then
  ok "cluster ${CLUSTER_NAME} already exists -- resuming"
  ensure_cluster_running || die "cluster is unhealthy; run: make down && make up"
else
  log "creating kind cluster '${CLUSTER_NAME}' via ${CONTAINER_CLI}"
  if ! kind create cluster --name "${CLUSTER_NAME}" \
        --config "${REPO_ROOT}/cluster/kind-config.yaml" \
        --image "${KIND_NODE_IMAGE}" --wait 180s; then
    # Almost always: node containers exist but kind's listing did not report them.
    if cluster_exists; then
      warn "create failed but node containers exist -- adopting them"
      ensure_cluster_running || die "adoption failed; run: make down && make up"
    else
      die "cluster creation failed"
    fi
  fi
fi

# Node labels, enforced.
#
# cluster/kind-config.yaml sets these at kubeadm time, but that path depends on a
# kind implementation detail (see the comment there). Applying them again here is
# idempotent, costs nothing, and turns a silent "everything Pending" failure into
# something that simply cannot happen.
log "applying node labels"
for node in $(kctl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  kctl label node "${node}" \
    llm-lab.io/pool=inference \
    llm-lab.io/accelerator=none \
    --overwrite >/dev/null
done
ok "nodes labelled: $(kctl get nodes -o jsonpath='{.items[*].metadata.name}')"

"${REPO_ROOT}/scripts/registry.sh"

# --- CRDs -------------------------------------------------------------------
# ALWAYS server-side.
#
# Client-side `kubectl apply` stores a full copy of the manifest in the
# kubectl.kubernetes.io/last-applied-configuration annotation. Several CRDs here
# (NGF's nginxproxies, Gateway API's, GIE's) exceed the 262144-byte annotation
# limit and fail with "metadata.annotations: Too long". Server-side apply keeps
# ownership in managedFields instead and has no such ceiling.
kapply_crds() {
  kctl apply --server-side --force-conflicts "$@"
}

# Switching channels in place is blocked by Gateway API itself.
#
# Since Gateway API v1.4 the CRD bundle ships a ValidatingAdmissionPolicy,
# safe-upgrades.gateway.networking.k8s.io, that rejects any apply which would
# install experimental CRDs over standard ones:
#
#   "Installing experimental CRDs on top of standard channel CRDs is prohibited
#    by default. Uninstall ValidatingAdmissionPolicy safe-upgrades... to install
#    experimental CRDs on top of standard channel CRDs."
#
# That is upstream's own escape hatch, so take it -- but only on a genuine
# channel change, so the guard keeps protecting every ordinary re-run. Both the
# policy and its binding are part of the bundle being applied, so they are
# recreated seconds later by the very next command. The installed channel is
# readable off any Gateway API CRD's channel annotation.
gwapi_installed_channel() {
  kctl get crd httproutes.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}' 2>/dev/null || true
}

current_channel="$(gwapi_installed_channel)"
if [[ -n "${current_channel}" && "${current_channel}" != "${GWAPI_CHANNEL}" ]]; then
  warn "Gateway API channel change: ${current_channel} -> ${GWAPI_CHANNEL}"
  warn "  dropping the safe-upgrades admission policy so the apply can proceed"
  warn "  (the CRD bundle below reinstates it immediately)"
  kctl delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io --ignore-not-found
  kctl delete validatingadmissionpolicy        safe-upgrades.gateway.networking.k8s.io --ignore-not-found
fi

# Gateway API comes from NGF's own version-pinned kustomize rather than upstream
# releases. NGF supports a specific Gateway API version; installing them
# independently is how you get subtle skew that surfaces as unimplemented fields.
log "installing Gateway API CRDs (${GWAPI_CHANNEL} channel, pinned by NGF v${NGF_VERSION})"
kubectl kustomize \
  "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/${GWAPI_CHANNEL}?ref=v${NGF_VERSION}" \
  | kapply_crds -f -

# Inference Extension CRDs, from NGF's own pinned kustomize.
#
# NGF v2.6.7 pins GIE v1.5.0, which is also what llm-d v0.8.0 vendors, so all
# three agree. Taking the CRDs from NGF's ref rather than a GIE release keeps
# that guarantee if NGF is bumped: the pin moves with the gateway that has to
# understand the resources.
log "installing Gateway API Inference Extension CRDs (pinned by NGF v${NGF_VERSION})"
kubectl kustomize \
  "https://github.com/nginx/nginx-gateway-fabric/config/crd/inference-extension/?ref=v${NGF_VERSION}" \
  | kapply_crds -f -

log "creating namespaces"
kctl apply -k "${REPO_ROOT}/manifests/base"

# --- NGINX Gateway Fabric ---------------------------------------------------
kapply_crds -f "https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v${NGF_VERSION}/deploy/crds.yaml"

# NGF is installed by whichever of three methods works. They are tried in order
# because a chart-registry failure should degrade, not halt the build.
#
#   oci      -- helm from ghcr (normal path)
#   source   -- git clone the tag, helm install from charts/ in the tree
#               (same chart, no chart registry involved; images still from ghcr)
#   manifest -- upstream's plain YAML; no helm at all, last resort
#
# Force one with NGF_INSTALL_METHOD=<oci|source|manifest>.
# The whole swap contract depends on this one setting.
#
# Every gateway overlay publishes Service/ai-gateway as an ExternalName alias to
# whatever the active chart actually created (see publish_ai_gateway). NGINX will
# not resolve an ExternalName target unless a DNS resolver is configured, and NGF
# surfaces that only in the HTTPRoute's status:
#   ResolvedRefs=False  "ExternalName service requires DNS resolver
#                        configuration in Gateway's NginxProxy"
# The data plane meanwhile answers every request with a bare 500, so without
# reading route status this looks like the AI gateway is broken.
#
# Discovered rather than hardcoded: 10.96.0.10 is only the default, and a cluster
# built with a different serviceSubnet lands elsewhere.
CLUSTER_DNS_IP="$(kctl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
[[ -n "${CLUSTER_DNS_IP}" ]] || die "could not discover the cluster DNS ClusterIP (kube-system/kube-dns)"
ok "cluster DNS for ExternalName resolution: ${CLUSTER_DNS_IP}"

NGF_VALUES=(
  --set nginxGateway.gatewayClassName="${NGF_GATEWAY_CLASS}"
  # Default is LoadBalancer, which never gets an address on kind/macOS.
  --set nginx.service.type=NodePort
  --set nginxGateway.resources.requests.cpu=50m
  --set nginxGateway.resources.requests.memory=64Mi
  --set nginx.config.dnsResolver.addresses[0].type=IPAddress
  --set nginx.config.dnsResolver.addresses[0].value="${CLUSTER_DNS_IP}"

  # Gateway API Inference Extension support -- what GATEWAY=ngf-llmd actually needs.
  #
  # This is a SEPARATE switch from gwAPIExperimentalFeatures below, and both are
  # off by default. Without it NGF simply does not understand an InferencePool
  # backendRef and reports
  #   ResolvedRefs=False BackendNotFound
  #   spec.rules[0].backendRefs[0].name: Not found: "primary-pool"
  # even though the pool is right there in the same namespace, which reads like
  # the pool is missing rather than like a feature being disabled.
  --set nginxGateway.gwAPIInferenceExtension.enable=true
  # This asserts the EPP in manifests/scheduler/llm-d/ "serves plaintext gRPC
  # on 9002 with no certificate mounted". That was never checked against the
  # EPP's actual startup flags and is only half true: it mounts no cert, but
  # it still defaults to `secure-serving=true` (GIE v1.5.0; confirmed via
  # `make logs-epp` -> "Flags processed" -> "secure-serving":true) and cannot
  # complete a handshake either way. With disableTLS=true (this line), NGF's
  # endpoint-picker-shim gets "error reading server preface: EOF" and every
  # ext_proc stream fails -- silently, because NGF's njs routing falls back to
  # plain round-robin over the InferencePool's raw Service rather than
  # erroring the request. `make smoke` passes throughout (chat completion
  # still works via the fallback), which is how this stayed undiscovered:
  # GATEWAY=ngf-llmd looked green while the EPP was never actually consulted.
  # Caught only in the Phase 3 multi-endpoint exercise, where mock backends
  # made the fallback's round-robin visible as an even split instead of
  # scheduler convergence.
  #
  # disableTLS=false (the chart's own default) does not fix it either -- the
  # EPP resets the connection ("connection reset by peer") since it has no
  # cert to complete a TLS handshake with regardless of what the client
  # trusts; `skipVerify` only relaxes CLIENT-side validation.
  #
  # The only combination that made NGF's ext_proc calls genuinely work was
  # symmetric plaintext: this line PLUS --secure-serving=false added to the
  # EPP's own args. Verified via `make logs-epp` showing real scheduler
  # decisions against a 3-endpoint pool. But that combination was reverted --
  # it breaks GATEWAY=envoy, which is already verified working and depends on
  # the EPP staying TLS: Envoy AI Gateway's ext_proc client speaks genuine TLS
  # to this same shared EPP, and gets
  #   TLS_error: ...WRONG_VERSION_NUMBER
  # against a plaintext one. The two gateways want opposite wire protocols
  # from one EPP Deployment with no per-Gateway override for it. Envoy's
  # working path is the one to protect, so this stays disableTLS=true (EPP
  # still secure-serving=true, default) and GATEWAY=ngf-llmd's EPP integration
  # stays a known, reproduced, NOT fixed defect -- see
  # docs/HomeLab_Runbook_v1.md and manifests/scheduler/llm-d/inferencepool.yaml.
  --set nginxGateway.gwAPIInferenceExtension.endpointPicker.disableTLS=true
)

# InferencePool as an HTTPRoute backendRef (GATEWAY=ngf-llmd) is an experimental
# Gateway API feature and needs both the experimental CRDs and this flag.
if [[ "${GWAPI_CHANNEL}" == "experimental" ]]; then
  NGF_VALUES+=(--set nginxGateway.gwAPIExperimentalFeatures.enable=true)
  ok "experimental Gateway API features enabled (required for GATEWAY=ngf-llmd)"
fi

install_ngf_oci() {
  CHART_INSTALL_METHOD=auto helm_chart_install ngf nginx-gateway \
    oci://ghcr.io/nginx/charts/nginx-gateway-fabric "${NGF_VERSION}" \
    https://github.com/nginx/nginx-gateway-fabric.git "v${NGF_VERSION}" \
    charts/nginx-gateway-fabric \
    "${NGF_VALUES[@]}" --wait --timeout 5m
}

install_ngf_source() {
  CHART_INSTALL_METHOD=source helm_chart_install ngf nginx-gateway \
    oci://ghcr.io/nginx/charts/nginx-gateway-fabric "${NGF_VERSION}" \
    https://github.com/nginx/nginx-gateway-fabric.git "v${NGF_VERSION}" \
    charts/nginx-gateway-fabric \
    "${NGF_VALUES[@]}" --wait --timeout 5m
}

install_ngf_manifest() {
  warn "manifest install: helm values are NOT applied (resource requests, experimental flag)"
  kctl apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v${NGF_VERSION}/deploy/nodeport/deploy.yaml"
}

ngf_installed=""
for method in ${NGF_INSTALL_METHOD:-oci source manifest}; do
  log "installing NGINX Gateway Fabric ${NGF_VERSION} via ${method}"
  if "install_ngf_${method}"; then
    # Report the path that actually worked. `oci` internally falls back to the
    # chart source, so ${method} alone would claim an OCI install that 403'd.
    ngf_installed="${HELM_CHART_METHOD_USED:-${method}}"
    ok "NGF installed via ${ngf_installed}"; break
  fi
  warn "${method} install failed"
  [[ "${method}" != "manifest" ]] && warn "  falling back -- run 'make doctor-registry' to see why"
done
[[ -n "${ngf_installed}" ]] || die "all NGF install methods failed; run: make doctor-registry"

# Deployment name differs between helm (ngf-nginx-gateway-fabric) and the plain
# manifests (nginx-gateway), so wait on whatever is actually there.
log "waiting for the NGF control plane"
for _ in $(seq 1 60); do
  dep="$(kctl -n nginx-gateway get deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${dep}" ]] && break
  sleep 3
done
[[ -n "${dep:-}" ]] || die "no NGF deployment appeared in namespace nginx-gateway"
wait_rollout nginx-gateway deployment "${dep}" 300s

log "creating ingress Gateway"
kctl apply -f "${REPO_ROOT}/manifests/ingress/ngf/gateway.yaml"

"${REPO_ROOT}/scripts/ingress-nodeport.sh"

ok "cluster up. next: make backends && make gateway"
