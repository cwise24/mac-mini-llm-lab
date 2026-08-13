#!/usr/bin/env bash
# Every image must have a linux/arm64 manifest. An amd64-only image will pull and
# then die with "exec format error" deep in a CrashLoop -- cheaper to catch here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

images=(
  "${NGINX_IMAGE}"
  "${EPP_IMAGE}"
  "docker.io/library/python:3.12-alpine"
  "docker.io/library/registry:2"
  "${KIND_NODE_IMAGE}"
  "ghcr.io/berriai/litellm:main-stable"
  "docker.io/maximhq/bifrost:latest"
  "${VLLM_UPSTREAM_IMAGE:-docker.io/mekayelanik/vllm-cpu:latest}"
)

log "checking linux/arm64 availability"
fail=0
for img in "${images[@]}"; do
  if out="$(ctr manifest inspect "${img}" 2>/dev/null)"; then
    if grep -q '"architecture": *"arm64"' <<<"${out}" || grep -q 'arm64' <<<"${out}"; then
      ok "${img}"
    else
      warn "NO arm64 manifest: ${img}"; fail=1
    fi
  else
    warn "could not inspect (may need login or may not exist): ${img}"
  fi
done

# vLLM is built locally, so just confirm it exists
if ctr image inspect "${VLLM_IMAGE}" >/dev/null 2>&1; then
  ok "${VLLM_IMAGE} (locally built)"
else
  warn "${VLLM_IMAGE} not built yet -- run: make build-vllm"
fi

if (( fail == 0 )); then ok "image check passed"; else warn "some images lack arm64; override them in .env"; fi
