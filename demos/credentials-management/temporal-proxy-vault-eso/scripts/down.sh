#!/usr/bin/env bash
# Delete the demo cluster. Touches nothing else: no other k3d cluster, and
# not Temporal Cloud, whose accepted CAs stay as the last script left them.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools k3d
k3d cluster delete "$CLUSTER_NAME"
