#!/usr/bin/env bash
# Look for lab resources under BOTH runtimes, not just the configured one.
#
# `make status` and `kind get clusters` only ever see the runtime named in .env.
# Anything left under the other one is invisible to every other command in this
# repo -- which is precisely what makes it worth a dedicated check.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

found=0
for rt in podman docker; do
  command -v "${rt}" >/dev/null 2>&1 || continue
  "${rt}" info >/dev/null 2>&1 || { log "${rt}: installed but not running"; continue; }

  nodes="$("${rt}" ps -a --filter "label=io.x-k8s.kind.cluster" \
            --format '{{.Names}}\t{{.State}}' 2>/dev/null || true)"
  reg="$("${rt}" ps -a --filter "name=${REGISTRY_NAME}" \
          --format '{{.Names}}\t{{.State}}' 2>/dev/null || true)"

  marker=""
  [[ "${rt}" == "${CONTAINER_CLI}" ]] && marker="  <- active (.env)"

  if [[ -z "${nodes}" && -z "${reg}" ]]; then
    ok "${rt}: clean${marker}"
    continue
  fi

  log "${rt}:${marker}"
  [[ -n "${nodes}" ]] && while read -r l; do [[ -n "${l}" ]] && echo "    node     ${l}"; done <<<"${nodes}"
  [[ -n "${reg}"   ]] && while read -r l; do [[ -n "${l}" ]] && echo "    registry ${l}"; done <<<"${reg}"

  if [[ "${rt}" != "${CONTAINER_CLI}" && -n "${nodes}" ]]; then
    found=1
    echo
    warn "    ORPHANED: .env says ${CONTAINER_CLI}, so kind cannot see these."
    warn "    They still hold disk and may still bind port 8080."
    warn "    Remove:  ${rt} rm -f \$(${rt} ps -aq --filter label=io.x-k8s.kind.cluster)"
  fi
  echo
done

(( found == 0 )) && ok "no orphans"
