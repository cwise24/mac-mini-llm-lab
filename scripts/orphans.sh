#!/usr/bin/env bash
# Look for lab resources under BOTH runtimes, not just the configured one.
#
# `make status` and `kind get clusters` only ever see the runtime named in .env.
# Anything left under the other one is invisible to every other command in this
# repo -- which is precisely what makes it worth a dedicated check.
#
# CAVEAT learned the hard way, 2026-08-16: `docker` and `podman` can be the
# SAME daemon under two CLI names. If DOCKER_HOST (or a docker context) points
# at podman's own socket -- `docker context ls` shows a `default` context
# doing exactly this on at least one machine this repo runs on -- `docker ps`
# returns podman's own containers verbatim, container ID and all. Reporting
# that as a second runtime's orphan is not a harmless false alarm: the fix it
# suggests, `docker rm -f ...`, deletes the ACTIVE podman cluster, not a
# stray one. Comparing container IDs (not just name/state) against the
# active runtime's catches this before it turns into that suggestion.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

active_ids="$("${CONTAINER_CLI}" ps -a --filter "label=io.x-k8s.kind.cluster" --format '{{.ID}}' 2>/dev/null || true)"

found=0
for rt in podman docker; do
  command -v "${rt}" >/dev/null 2>&1 || continue
  "${rt}" info >/dev/null 2>&1 || { log "${rt}: installed but not running"; continue; }

  ids="$("${rt}" ps -a --filter "label=io.x-k8s.kind.cluster" --format '{{.ID}}' 2>/dev/null || true)"
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

  if [[ "${rt}" != "${CONTAINER_CLI}" && -n "${ids}" && -n "${active_ids}" \
        && "${ids}" == "${active_ids}" ]]; then
    ok "${rt}: same container IDs as ${CONTAINER_CLI} -- same daemon under a second CLI name (check: docker context ls / \$DOCKER_HOST), not an orphan"
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
