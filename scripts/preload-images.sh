#!/usr/bin/env bash
# Pull images with podman on the host, then side-load them into the kind node.
#
# Why this exists: installing charts from git source avoids the OCI *chart*
# registry, but the workloads still pull *container images* -- and NGF's live on
# ghcr.io (ghcr.io/nginx/nginx-gateway-fabric). Those pulls are done by containerd
# inside the kind node, a different client on a different path than helm. If the
# ghcr problem on this machine turns out to be network-level rather than
# client-level, image pulls fail next as ImagePullBackOff.
#
# podman has already proven it can pull from ghcr here (that is how the vLLM
# image arrived), so pulling host-side and loading into the node sidesteps it.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGES=(
  "ghcr.io/nginx/nginx-gateway-fabric:${NGF_VERSION}"
  "ghcr.io/nginx/nginx-gateway-fabric/nginx:${NGF_VERSION}"
  "${EPP_IMAGE}"
  "${NGINX_IMAGE}"
  "docker.io/library/python:3.12-alpine"
)

cluster_exists || die "cluster ${CLUSTER_NAME} not found; run 'make up' first"

for img in "${IMAGES[@]}"; do
  log "pulling ${img}"
  if ! ctr pull --platform linux/arm64 "${img}" >/dev/null 2>&1; then
    warn "  pull failed, skipping (may not exist for this version)"
    continue
  fi
  log "  loading into kind node"
  if ctr save "${img}" -o "${STATE_DIR}/img.tar" >/dev/null 2>&1 \
     && kind load image-archive "${STATE_DIR}/img.tar" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
    ok "  ${img}"
  else
    warn "  side-load failed for ${img}"
  fi
  rm -f "${STATE_DIR}/img.tar"
done

ok "preload complete. Pods will find these locally (imagePullPolicy IfNotPresent)."
