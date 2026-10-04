#!/usr/bin/env bash
# Stage 60-logging — Loki and Fluentd
# Sourced by deploy.sh; can also run alone: sudo ./scripts/60-logging.sh
#
#   Fluentd (DaemonSet, ns logging) --push--> Loki (Monolithic, Service loki:3100, ns logging)
#   Grafana (stage 50) reads Loki through its datasource; alerts are in charts/observability.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_standalone_init

LOGGING_NS=logging
LOKI_REPO=https://grafana-community.github.io/helm-charts
FLUENTD_REPO=https://fluent.github.io/helm-charts

logging_values() {  # logging_values NAME -> "-f values/NAME.yaml [-f values/NAME-small.yaml]"
  local name=$1
  printf '%s\n' -f "$REPO_ROOT/values/$name.yaml"
  if [[ "$PROFILE" == small && -f "$REPO_ROOT/values/$name-small.yaml" ]]; then
    printf '%s\n' -f "$REPO_ROOT/values/$name-small.yaml"
  fi
}

step "logging: prerequisites"
# Loki keeps its data on a PVC; without a default StorageClass the release would wait for the
# full Helm timeout and then fail with an unclear message.
if ! kc get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null | grep -qx true; then
  die "no default StorageClass in the cluster (stage 20-cluster installs local-path). Run: sudo ./deploy.sh"
fi
ok "default StorageClass present"
if ! kc get namespace "$LOGGING_NS" >/dev/null 2>&1; then
  warn "namespace $LOGGING_NS is missing (stage 30-platform creates it with its Pod Security labels); Helm will create a plain one"
fi

step "logging: Loki ${LOKI_VERSION} (chart ${LOKI_CHART_VERSION})"
mapfile -t loki_args < <(logging_values loki)
helm_release loki "$LOGGING_NS" loki "$LOKI_CHART_VERSION" \
  --repo "$LOKI_REPO" \
  "${loki_args[@]}" \
  --set "loki.image.tag=${LOKI_VERSION}"

# The datasource of Grafana and the Fluentd output both use Service loki:3100.
loki_ready() { kc get --raw "/api/v1/namespaces/${LOGGING_NS}/services/loki:3100/proxy/ready" 2>/dev/null | grep -q '^ready'; }
wait_for 180 "Loki /ready (Service ${LOGGING_NS}/loki:3100)" loki_ready
ok "Loki ready at http://loki.${LOGGING_NS}.svc.cluster.local:3100"

step "logging: Fluentd (chart ${FLUENTD_CHART_VERSION}, image ${FLUENTD_IMAGE}:${FLUENTD_IMAGE_TAG})"
mapfile -t fluentd_args < <(logging_values fluentd)
helm_release fluentd "$LOGGING_NS" fluentd "$FLUENTD_CHART_VERSION" \
  --repo "$FLUENTD_REPO" \
  "${fluentd_args[@]}" \
  --set "image.repository=${FLUENTD_IMAGE}" \
  --set "image.tag=${FLUENTD_IMAGE_TAG}"

fluentd_ready() {
  local desired ready
  desired="$(kc -n "$LOGGING_NS" get daemonset fluentd -o jsonpath='{.status.desiredNumberScheduled}')"
  ready="$(kc -n "$LOGGING_NS" get daemonset fluentd -o jsonpath='{.status.numberReady}')"
  [[ -n "$desired" && "$desired" -gt 0 && "$ready" == "$desired" ]]
}
wait_for 180 "Fluentd DaemonSet ready on every node" fluentd_ready
ok "Fluentd running on every node (metrics :24231/metrics)"
info "check end-to-end delivery: ./scripts/demo-logs.sh"
