#!/usr/bin/env bash
# Switch the container runtime, refusing to strand an existing cluster.
#
# Why this is a script and not `sed -i s/CONTAINER_CLI=.../`:
#
# kind clusters are not portable between docker and podman. Switching while one
# exists does not error -- the containers keep running under the OLD runtime, but
# `kind get clusters` (now asking the NEW one) reports nothing. The cluster looks
# deleted while still holding several GB of disk and its port bindings on 8080.
# The next `make up` then builds a second cluster, and the first is invisible
# unless you happen to run the old runtime's `ps` by hand.
#
# A doc note is not enough protection for a failure that leaves no trace. So:
# detect the cluster under the current runtime and refuse until it is gone.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET="${1:-}"
[[ "${TARGET}" == "docker" || "${TARGET}" == "podman" ]] \
  || die "usage: switch-runtime.sh <docker|podman>"

CURRENT="${CONTAINER_CLI}"

if [[ "${CURRENT}" == "${TARGET}" ]]; then
  ok "already using ${TARGET}; nothing to do"
  exit 0
fi

command -v "${TARGET}" >/dev/null 2>&1 \
  || die "${TARGET} is not installed. brew install ${TARGET}$([[ ${TARGET} == docker ]] && echo ' --cask')"

# Is a cluster still live under the runtime we are leaving?
stranded="$("${CURRENT}" ps -a \
  --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
  --format '{{.Names}}' 2>/dev/null || true)"

if [[ -n "${stranded}" && "${FORCE:-0}" != "1" ]]; then
  echo
  warn "a kind cluster still exists under ${CURRENT}:"
  while read -r n; do [[ -n "${n}" ]] && warn "    ${n}"; done <<<"${stranded}"
  echo
  warn "Switching now would ORPHAN it: still running, still holding disk and"
  warn "port 8080, but invisible to kind once the provider changes."
  echo
  warn "  Tear it down first (recommended):"
  warn "      make down && make use-${TARGET}"
  echo
  warn "  Or switch anyway and clean up later:"
  warn "      FORCE=1 make use-${TARGET}"
  warn "      ${CURRENT} rm -f \$(${CURRENT} ps -aq --filter label=io.x-k8s.kind.cluster=${CLUSTER_NAME})"
  echo
  die "refusing to strand a running cluster"
fi

if [[ -n "${stranded}" ]]; then
  warn "FORCE=1: leaving these containers behind under ${CURRENT}:"
  while read -r n; do [[ -n "${n}" ]] && warn "    ${n}"; done <<<"${stranded}"
  warn "remove them with: ${CURRENT} rm -f \$(${CURRENT} ps -aq --filter label=io.x-k8s.kind.cluster=${CLUSTER_NAME})"
fi

# The registry is runtime-scoped too -- it holds the vLLM image.
if "${CURRENT}" inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
  warn "registry '${REGISTRY_NAME}' lives under ${CURRENT} and will not follow you."
  warn "  ${TARGET} will start a fresh one; 'make build-vllm' re-pulls the image (~550 MB)."
fi

sed -i.bak "s/^CONTAINER_CLI=.*/CONTAINER_CLI=${TARGET}/" "${REPO_ROOT}/.env"
rm -f "${REPO_ROOT}/.env.bak"

ok "runtime: ${CURRENT} -> ${TARGET}"
echo
log "next:"
echo "    make preflight     # check ${TARGET} has enough CPU/RAM"
echo "    make bootstrap     # build the cluster on ${TARGET}"
