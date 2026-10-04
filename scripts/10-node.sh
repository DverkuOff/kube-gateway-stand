#!/usr/bin/env bash
# Stage 10-node — kernel settings, containerd, kubeadm/kubelet/kubectl, helm
# Owner: track A. Sourced by deploy.sh; can also run alone: sudo ./scripts/10-node.sh
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_standalone_init

warn "stage 10-node is not implemented yet"
