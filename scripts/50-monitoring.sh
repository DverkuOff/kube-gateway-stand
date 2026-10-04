#!/usr/bin/env bash
# Stage 50-monitoring — kube-prometheus-stack, Grafana route, dashboards, alerts
# Sourced by deploy.sh; can also run alone: sudo ./scripts/50-monitoring.sh
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_standalone_init

MON_NS=monitoring
KPS_REPO=https://prometheus-community.github.io/helm-charts

step "monitoring: prerequisites"
kc get namespace "$MON_NS" >/dev/null 2>&1 \
  || die "namespace $MON_NS is missing; run stage 30-platform first: sudo ONLY_STAGES=30-platform ./deploy.sh"
for crd in prometheuses.monitoring.coreos.com servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com httproutes.gateway.networking.k8s.io; do
  kc get crd "$crd" >/dev/null 2>&1 \
    || die "CRD $crd is missing; stage 30-platform applies the Prometheus Operator and Gateway API CRDs"
done
ok "namespace $MON_NS and CRDs present"

# --- Grafana admin credentials -----------------------------------------------------------
# Generated once, never printed; created from stdin (not --from-literal, not apply) so the
# password is neither visible in the process list nor stored in a last-applied annotation.
# Delete the Secret and re-run the stage to rotate it: a running Grafana is restarted to pick it up.
step "monitoring: Grafana admin Secret"
if kc -n "$MON_NS" get secret grafana-admin >/dev/null 2>&1; then
  ok "secret $MON_NS/grafana-admin exists"
else
  grafana_password="$(openssl rand -hex 16)"
  kc create -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: $MON_NS
  labels:
    app.kubernetes.io/part-of: kube-gateway-stand
type: Opaque
stringData:
  admin-user: admin
  admin-password: $grafana_password
EOF
  unset grafana_password
  changed "secret $MON_NS/grafana-admin created (show it with ./scripts/creds.sh)"
  # Grafana stores the admin password in its database (emptyDir) on first start and would keep the
  # old one, so `make creds` would show a password that does not work: restart it with the new Secret.
  if kc -n "$MON_NS" get deployment kps-grafana >/dev/null 2>&1; then
    kc -n "$MON_NS" rollout restart deployment/kps-grafana >/dev/null
    kc -n "$MON_NS" rollout status deployment/kps-grafana --timeout=300s >/dev/null ||
      die "Grafana did not restart with the new admin Secret: kubectl -n $MON_NS get pods -l app.kubernetes.io/name=grafana"
    changed "Grafana restarted to use the new admin password"
  fi
fi

# --- Grafana sidecar RBAC ----------------------------------------------------------------
# The dashboard/datasource sidecars only need ConfigMaps in this namespace. The Grafana chart's
# own namespaced Role would also grant Secrets, so the release binds to this Role instead.
step "monitoring: Grafana sidecar Role"
kapply - "Role $MON_NS/grafana-sidecar" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: grafana-sidecar
  namespace: $MON_NS
  labels:
    app.kubernetes.io/part-of: kube-gateway-stand
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
EOF

# --- kube-prometheus-stack ---------------------------------------------------------------
step "monitoring: kube-prometheus-stack ${KPS_CHART_VERSION}"
kps_args=(--repo "$KPS_REPO" -f "$REPO_ROOT/values/kps.yaml")
if [[ "$PROFILE" == small ]]; then
  kps_args+=(-f "$REPO_ROOT/values/kps-small.yaml")
fi
kps_args+=(--set "grafana.grafana\.ini.server.root_url=https://${GRAFANA_HOST}")
helm_release kps "$MON_NS" kube-prometheus-stack "$KPS_CHART_VERSION" "${kps_args[@]}"

# helm --wait covers the operator, Grafana, kube-state-metrics and node-exporter; the Prometheus
# StatefulSet is created by the operator afterwards.
prometheus_available() {
  [[ "$(kc -n "$MON_NS" get prometheus kps-prometheus \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" == True ]]
}
if prometheus_available; then
  ok "Prometheus available"
else
  info "waiting for Prometheus to become available (PVC, image pull)..."
  wait_for 600 "Prometheus $MON_NS/kps-prometheus Available (kubectl -n $MON_NS describe prometheus kps-prometheus)" prometheus_available
  ok "Prometheus available"
fi

# --- Grafana route, alert rules, dashboards ----------------------------------------------
step "monitoring: Grafana route, alerts, dashboards"
dashboards_sum="$(cat "$REPO_ROOT"/dashboards/*.json | sha256sum | cut -c1-16)"
helm_release observability "$MON_NS" "$REPO_ROOT/charts/observability" "" \
  --set "grafanaHost=${GRAFANA_HOST}" \
  --set-string "dashboards.checksum=${dashboards_sum}"

grafana_route_accepted() {
  [[ "$(kc -n "$MON_NS" get httproute grafana \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == True ]]
}
route_deadline=$((SECONDS + 60))
until grafana_route_accepted || ((SECONDS >= route_deadline)); do sleep 3; done
if grafana_route_accepted; then
  ok "HTTPRoute $MON_NS/grafana accepted by the Gateway"
else
  warn "HTTPRoute $MON_NS/grafana is not Accepted yet: kubectl -n $MON_NS describe httproute grafana"
fi
info "Grafana: https://${GRAFANA_HOST}  (login and password: ./scripts/creds.sh)"
