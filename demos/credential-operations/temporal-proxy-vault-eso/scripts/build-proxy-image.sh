#!/usr/bin/env bash
# Build the Temporal Proxy image at TEMPORAL_PROXY_REF and import it into the
# demo cluster (when the cluster exists).
#
# Source: TEMPORAL_PROXY_SRC (an existing local checkout) if set, otherwise a
# fresh clone of TEMPORAL_PROXY_REPO.
#
# Verify: `docker image inspect temporal-proxy:<ref>` succeeds, and after
# import the image is listed by `docker exec k3d-<cluster>-server-0 crictl images`.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools docker git tar

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "${TEMPORAL_PROXY_SRC:-}" ]; then
  log "Exporting $TEMPORAL_PROXY_REF from $TEMPORAL_PROXY_SRC"
  git -C "$TEMPORAL_PROXY_SRC" archive "$TEMPORAL_PROXY_REF" | tar -x -C "$work"
else
  log "Cloning $TEMPORAL_PROXY_REPO at $TEMPORAL_PROXY_REF"
  git clone --quiet "$TEMPORAL_PROXY_REPO" "$work/src"
  git -C "$work/src" archive "$TEMPORAL_PROXY_REF" | tar -x -C "$work"
  rm -rf "$work/src"
fi

docker build -f "$DEMO_DIR/docker/temporal-proxy.Dockerfile" -t "$TEMPORAL_PROXY_IMAGE" "$work"
docker image inspect "$TEMPORAL_PROXY_IMAGE" >/dev/null
log "Built $TEMPORAL_PROXY_IMAGE"

if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
  k3d image import "$TEMPORAL_PROXY_IMAGE" --cluster "$CLUSTER_NAME"
  log "Imported $TEMPORAL_PROXY_IMAGE into $CLUSTER_NAME"
fi
