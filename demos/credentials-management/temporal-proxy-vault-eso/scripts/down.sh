#!/usr/bin/env bash
# Delete the demo cluster. Touches nothing else: Temporal Cloud is unchanged in
# milestone 1, and no other k3d cluster is affected.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools k3d
k3d cluster delete "$CLUSTER_NAME"
