#!/usr/bin/env bash
# Stage 20-cluster — kubeadm init, kubeconfig, Calico, local-path storage
# Owner: track A. Sourced by deploy.sh; can also run alone: sudo ./scripts/20-cluster.sh
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_standalone_init

warn "stage 20-cluster is not implemented yet"
