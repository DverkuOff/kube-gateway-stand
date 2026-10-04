#!/usr/bin/env bash
# One-command deployment on a clean Ubuntu 24.04 host:  sudo ./deploy.sh
# Safe to re-run: every stage checks the current state and changes only what differs.
#
# Environment overrides (all optional):
#   NODE_IP            node address (default: source address of the default route)
#   POD_CIDR/SVC_CIDR  cluster networks (default 10.244.0.0/16 / 10.96.0.0/16)
#   PROFILE            default | small  (small: lower requests/retention for 2 vCPU / 4 GB)
#   DOCKERHUB_MIRROR   registry mirror for docker.io (default https://mirror.gcr.io, "" = none)
#   CONTAINERD_SOURCE  ubuntu | docker (use docker where Docker's containerd.io is already installed)
#   CANARY_WEIGHT      share of traffic for v2 in percent (default 20)
#   ONLY_STAGES        space-separated subset of stages to run, e.g. "30-platform 40-app"
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

if [[ $EUID -ne 0 ]]; then
  exec sudo --preserve-env=NODE_IP,POD_CIDR,SVC_CIDR,PROFILE,DOCKERHUB_MIRROR,CONTAINERD_SOURCE,ONLY_STAGES,HOST_SUFFIX,CANARY_WEIGHT,GATEWAY_TIMEOUT "$0" "$@"
fi

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"
trap 'on_error $LINENO "$BASH_COMMAND"' ERR
export KGS_DEPLOY=1
load_config

STAGES=(
  00-preflight    # OS, resources, ports, networks, registry access
  10-node         # kernel settings, containerd, kubeadm/kubelet/kubectl, helm
  20-cluster      # kubeadm init, kubeconfig, Calico, local-path storage
  30-platform     # CRDs, namespaces, cert-manager, Traefik, GatewayClass/Gateway, TLS
  40-app          # demo web app v1/v2 and its HTTPRoutes
  50-monitoring   # kube-prometheus-stack, dashboards, alerts
  60-logging      # Loki and Fluentd
)

started=$SECONDS
for stage in "${STAGES[@]}"; do
  if [[ -n "${ONLY_STAGES:-}" && " $ONLY_STAGES " != *" $stage "* ]]; then
    continue
  fi
  step "stage $stage"
  stage_started=$SECONDS
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/$stage.sh"
  info "stage $stage took $((SECONDS - stage_started))s"
done

summary
printf 'Elapsed: %ss\n' "$((SECONDS - started))"
if [[ -z "${ONLY_STAGES:-}" ]]; then
  # shellcheck source=scripts/access-info.sh
  source "$REPO_ROOT/scripts/access-info.sh"
fi
