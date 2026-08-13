#!/usr/bin/env bash
# Pinpoint WHY a registry pull fails, instead of guessing.
#
# A 403 from ghcr's token endpoint has several distinct causes that look
# identical from helm's output. Each check below isolates one.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_PATH="nginx/charts/nginx-gateway-fabric"
VER="${NGF_VERSION}"

echo
log "1. proxy / TLS-interception environment"
found=0
for v in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy \
         SSL_CERT_FILE REQUESTS_CA_BUNDLE CURL_CA_BUNDLE; do
  [[ -n "${!v:-}" ]] && { printf '   %-20s = %s\n' "$v" "${!v}"; found=1; }
done
(( found )) || echo "   none set"
(( found )) && warn "a proxy or custom CA can turn an anonymous pull into a 403"

echo
log "2. anonymous token, straight from curl (no helm, no auth)"
tok_body="$(curl -sS --max-time 15 \
  "https://ghcr.io/token?scope=repository%3A${REPO_PATH//\//%2F}%3Apull&service=ghcr.io" 2>&1 || true)"
if grep -q '"token"' <<<"${tok_body}"; then
  ok "   anonymous token issued -> ghcr is reachable and the repo is public"
  TOKEN="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' <<<"${tok_body}" 2>/dev/null || true)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json" \
    "https://ghcr.io/v2/${REPO_PATH}/manifests/${VER}")"
  if [[ "${code}" == "200" ]]; then
    ok "   manifest for ${VER} -> HTTP 200"
    echo "      => the network and the chart are FINE. The problem is in the helm client."
  else
    warn "   manifest for ${VER} -> HTTP ${code}"
    echo "      => version may not exist; try: make versions"
  fi
else
  warn "   no anonymous token. response:"
  sed 's/^/      /' <<<"$(head -c 400 <<<"${tok_body}")"
  echo "      => network-level block, proxy, or DNS interception. Not a credentials issue."
fi

echo
log "3. local auth stores mentioning ghcr.io"
found=0
for f in "${HOME}/.config/helm/registry/config.json" "${HOME}/.docker/config.json" \
         "${HOME}/.config/containers/auth.json" \
         "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json"; do
  if [[ -f "${f}" ]] && grep -q 'ghcr\.io' "${f}" 2>/dev/null; then
    warn "   ${f}"; found=1
  fi
done
(( found )) || ok "   none"
[[ -n "${HELM_REGISTRY_CONFIG:-}" ]] && warn "   HELM_REGISTRY_CONFIG=${HELM_REGISTRY_CONFIG} overrides --registry-config"

echo
log "4. helm client"
helm version --short 2>/dev/null | sed 's/^/   /'

echo
log "5. helm fetching the chart, forced anonymous"
cfg="${STATE_DIR}/helm-anon-registry.json"; echo '{"auths":{}}' > "${cfg}"
if out="$(helm show chart "oci://ghcr.io/${REPO_PATH}" --version "${VER}" \
          --registry-config "${cfg}" 2>&1)"; then
  ok "   helm CAN fetch the chart anonymously"
  grep -E '^(name|version|appVersion):' <<<"${out}" | sed 's/^/      /'
  echo "      => if 'make up' still fails, the flag is not reaching helm; report this."
else
  warn "   helm cannot fetch it. error:"
  sed 's/^/      /' <<<"$(tail -3 <<<"${out}")"
fi

echo
log "6. helm using your normal credentials"
if helm show chart "oci://ghcr.io/${REPO_PATH}" --version "${VER}" >/dev/null 2>&1; then
  ok "   works with host auth too -> set HELM_USE_HOST_AUTH=1"
else
  warn "   also fails with host auth"
fi

echo
log "7. helm with DOCKER_CONFIG isolated (the fix in lib.sh)"
dcfg="${STATE_DIR}/anon-docker-config"; mkdir -p "${dcfg}"; echo '{}' > "${dcfg}/config.json"
if DOCKER_CONFIG="${dcfg}" HELM_REGISTRY_CONFIG="${cfg}" \
   helm show chart "oci://ghcr.io/${REPO_PATH}" --version "${VER}" \
   --registry-config "${cfg}" >/dev/null 2>&1; then
  ok "   WORKS -> docker credential helpers were the cause; 'make up' will use the oci path"
else
  warn "   still fails -> credential isolation is not enough on this helm build"
  warn "   use: NGF_INSTALL_METHOD=source make up   (same chart, no chart registry)"
fi

echo
log "8. which helm binary is this, and is the failure ghcr-specific?"
echo "   PATH candidates:"
which -a helm 2>/dev/null | sed 's/^/      /'
hb="$(command -v helm)"
echo "   in use: ${hb}"
case "${hb}" in
  *conda*|*miniforge*|*anaconda*|*mambaforge*)
    warn "   this helm came from a conda environment."
    warn "   conda builds vendor their own TLS/auth stack and are a known source of"
    warn "   registry auth failures that the official build does not have."
    warn "   try:  brew install helm  &&  hash -r  &&  make doctor-registry" ;;
  *) ok "   not a conda build" ;;
esac
# macOS helm keeps its registry config under Library/Preferences, NOT ~/.config
for f in "${HOME}/Library/Preferences/helm/registry/config.json"; do
  [[ -f "${f}" ]] && { warn "   macOS helm config exists: ${f}"; grep -q 'ghcr\.io' "${f}" 2>/dev/null && warn "      ...and it mentions ghcr.io"; }
done

echo "   testing a different public OCI chart (docker.io):"
if helm show chart oci://docker.io/envoyproxy/gateway-helm --version "${ENVOY_GATEWAY_VERSION}" \
     --registry-config "${cfg}" >/dev/null 2>&1; then
  ok "      docker.io OCI works -> failure is ghcr-specific"
else
  warn "      docker.io OCI ALSO fails -> this helm binary cannot do OCI at all."
  warn "      That points at the client, not at any registry. Use a different helm,"
  warn "      or rely on the source-install fallbacks (NGF_INSTALL_METHOD=source)."
fi

echo
log "9. IPv4 vs IPv6 to ghcr.io"
# Why this matters: curl and Go resolve and connect differently. Go's dialer
# prefers IPv6 when a AAAA record exists, while curl on macOS often lands on
# IPv4. If this network's IPv6 egress is blocked, NAT64'd, or on a reputation
# list, ghcr answers 403 over v6 and 200 over v4 -- which looks exactly like an
# auth failure and is not one. docker.io succeeding while ghcr fails fits this,
# since the two use different edge networks.
echo "   DNS:"
{ dig +short A ghcr.io | head -3 | sed 's/^/      A    /'; } 2>/dev/null || true
{ dig +short AAAA ghcr.io | head -3 | sed 's/^/      AAAA /'; } 2>/dev/null || true

tok_url="https://ghcr.io/token?scope=repository%3A${REPO_PATH//\//%2F}%3Apull&service=ghcr.io"
c4="$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 12 "${tok_url}" 2>/dev/null || echo "conn-fail")"
c6="$(curl -6 -s -o /dev/null -w '%{http_code}' --max-time 12 "${tok_url}" 2>/dev/null || echo "conn-fail")"
echo "   token over IPv4: ${c4}"
echo "   token over IPv6: ${c6}"

if [[ "${c4}" == "200" && "${c6}" != "200" && "${c6}" != "conn-fail" ]]; then
  warn "   CONFIRMED: ghcr rejects this network over IPv6 but accepts IPv4."
  warn "   helm (Go) prefers IPv6; curl used IPv4. That is the whole difference."
  warn "   Fix by pinning ghcr.io to IPv4 in /etc/hosts:"
  warn "     echo \"$(dig +short A ghcr.io | head -1) ghcr.io\" | sudo tee -a /etc/hosts"
  warn "   Then: make doctor-registry"
elif [[ "${c4}" == "200" && "${c6}" == "conn-fail" ]]; then
  ok "   no usable IPv6 route; Go should fall back to IPv4 on its own"
  echo "      => IPv6 is probably not the cause"
else
  ok "   IPv4 and IPv6 behave the same; IPv6 is not the cause"
fi

echo
log "verdict"
echo "   step 2 OK + step 5 FAIL  -> helm client/config problem; use the fallbacks in up.sh"
echo "   step 2 FAIL              -> network/proxy blocking ghcr; NGF_INSTALL_METHOD=manifest"
echo "   step 5 OK                -> re-run 'make up'; it should now succeed"
echo
