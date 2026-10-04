#!/usr/bin/env bash
# Stage 30-platform — CRDs, namespaces, cert-manager, Traefik, GatewayClass/Gateway, TLS
# Sourced by deploy.sh; can also run alone: sudo ./scripts/30-platform.sh
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_standalone_init

[[ -n "${NODE_IP:-}" ]] || die "NODE_IP is empty: set it explicitly, e.g. NODE_IP=192.0.2.10 sudo ./deploy.sh"

PLATFORM_CACHE="$STATE_DIR/cache"
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
# stripped-down-crds.yaml: only the monitoring.coreos.com CRDs (no operator), descriptions removed.
PROM_CRDS_URL="https://github.com/prometheus-operator/prometheus-operator/releases/download/${PROMETHEUS_OPERATOR_VERSION}/stripped-down-crds.yaml"
TRAEFIK_REPO_URL="https://traefik.github.io/charts"
CERT_MANAGER_CHART="oci://quay.io/jetstack/charts/cert-manager"

# platform_fetch URL DEST — downloads once into the cache (versioned file name), with retries.
platform_fetch() {
  local url=$1 dest=$2
  if [[ -s "$dest" ]] && grep -q '^kind: CustomResourceDefinition' "$dest"; then
    ok "cached $(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  if ! retry 5 5 curl -fsSL --connect-timeout 15 --max-time 300 -o "$dest.part" "$url"; then
    rm -f "$dest.part"
    die "cannot download $url — check access to github.com (proxy/firewall) and re-run"
  fi
  grep -q '^kind: CustomResourceDefinition' "$dest.part" || { rm -f "$dest.part"; die "unexpected content from $url"; }
  mv "$dest.part" "$dest"
  changed "downloaded $(basename "$dest")"
}

# platform_wait_crds REGEX — waits until every CRD whose name matches REGEX is Established.
platform_wait_crds() {
  local regex=$1 crds
  crds="$(kc get crd -o name | grep -E "$regex" || true)"
  [[ -n "$crds" ]] || die "no CRDs matching $regex after apply"
  # shellcheck disable=SC2086  # word splitting of the CRD list is intended
  kc wait --for=condition=Established --timeout=120s $crds >/dev/null \
    || die "CRDs matching $regex are not Established after 120s (kubectl get crd)"
  ok "CRDs Established: $(wc -l <<<"$crds" | tr -d ' ') matching $regex"
}

platform_traefik_repo() {
  local url
  url="$(helm repo list -o json 2>/dev/null | jq -r '.[] | select(.name == "traefik") | .url' || true)"
  if [[ "$url" != "$TRAEFIK_REPO_URL" ]]; then
    retry 3 5 helm repo add traefik "$TRAEFIK_REPO_URL" --force-update >/dev/null \
      || die "cannot add Helm repository $TRAEFIK_REPO_URL"
    changed "helm repo traefik added"
  fi
  if ! helm search repo traefik/traefik --version "$TRAEFIK_CHART_VERSION" -o json 2>/dev/null | jq -e 'length > 0' >/dev/null; then
    retry 3 5 helm repo update traefik >/dev/null || die "cannot update Helm repository traefik"
    helm search repo traefik/traefik --version "$TRAEFIK_CHART_VERSION" -o json | jq -e 'length > 0' >/dev/null \
      || die "chart traefik/traefik $TRAEFIK_CHART_VERSION not found in $TRAEFIK_REPO_URL"
    changed "helm repo traefik updated"
  else
    ok "helm repo traefik has chart $TRAEFIK_CHART_VERSION"
  fi
}

platform_gateway_diagnostics() {
  warn "Gateway gateway/web status:"
  kc -n gateway get gateway web -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' >&2 || true
  kc -n gateway get gateway web -o jsonpath='{range .status.listeners[*]}listener {.name}: {range .conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}' >&2 || true
  warn "last Traefik log lines:"
  kc -n gateway logs deploy/traefik --tail=20 >&2 || true
}

# ---------- 1. CRDs (Gateway API standard channel, Prometheus Operator) ----------
step "CRDs: Gateway API ${GATEWAY_API_VERSION}, Prometheus Operator ${PROMETHEUS_OPERATOR_VERSION}"
gw_crds="$PLATFORM_CACHE/gateway-api-standard-${GATEWAY_API_VERSION}.yaml"
prom_crds="$PLATFORM_CACHE/prometheus-operator-crds-${PROMETHEUS_OPERATOR_VERSION}.yaml"
platform_fetch "$GATEWAY_API_URL" "$gw_crds"
platform_fetch "$PROM_CRDS_URL" "$prom_crds"
kapply "$gw_crds"
kapply "$prom_crds"
platform_wait_crds '\.gateway\.networking\.k8s\.io$'
platform_wait_crds '\.monitoring\.coreos\.com$'

# ---------- 2. Namespaces with Pod Security labels ----------
step "namespaces"
kapply "$REPO_ROOT/manifests/namespaces.yaml"

# ---------- 3. cert-manager ----------
step "cert-manager ${CERT_MANAGER_VERSION}"
helm_release cert-manager cert-manager "$CERT_MANAGER_CHART" "$CERT_MANAGER_VERSION" \
  -f "$REPO_ROOT/values/cert-manager.yaml"

# ---------- 4. Traefik ----------
step "Traefik ${TRAEFIK_VERSION} (chart ${TRAEFIK_CHART_VERSION})"
platform_traefik_repo
# The chart's crds/ holds only traefik.io and hub.traefik.io CRDs (installed by Helm on first install);
# Gateway API CRDs come from step 1 and are not touched by the chart.
helm_release traefik gateway traefik/traefik "$TRAEFIK_CHART_VERSION" \
  -f "$REPO_ROOT/values/traefik.yaml" \
  --set "image.tag=${TRAEFIK_VERSION}" \
  --set "providers.kubernetesGateway.statusAddress.ip=${NODE_IP}"

# ---------- 5. GatewayClass, Gateway, redirect, TLS chain ----------
step "platform: GatewayClass, Gateway, TLS"
helm_release platform gateway "$REPO_ROOT/charts/platform" "" \
  --set "nodeIP=${NODE_IP}" \
  --set "hostSuffix=${HOST_SUFFIX}"

kc -n cert-manager wait --for=condition=Ready certificate/platform-ca --timeout=120s >/dev/null \
  || die "Certificate cert-manager/platform-ca is not Ready (kubectl -n cert-manager describe certificate platform-ca)"
kc -n gateway wait --for=condition=Ready certificate/web-tls --timeout=120s >/dev/null \
  || die "Certificate gateway/web-tls is not Ready (kubectl -n gateway describe certificate web-tls)"
ok "certificates Ready: platform-ca, web-tls (*.${HOST_SUFFIX})"

kc wait --for=condition=Accepted gatewayclass/traefik --timeout=120s >/dev/null \
  || die "GatewayClass traefik is not Accepted: is Traefik running? (kubectl -n gateway get pods)"
if ! kc -n gateway wait --for=condition=Programmed gateway/web --timeout="${GATEWAY_TIMEOUT:-180}s" >/dev/null; then
  platform_gateway_diagnostics
  die "Gateway gateway/web is not Programmed after ${GATEWAY_TIMEOUT:-180}s"
fi
gw_addr="$(kc -n gateway get gateway web -o jsonpath='{.status.addresses[0].value}')"
if [[ "$gw_addr" == "$NODE_IP" ]]; then
  ok "Gateway web Programmed, address $gw_addr"
else
  warn "Gateway web Programmed, but status address is '${gw_addr}' (expected $NODE_IP)"
fi

# ---------- 6. CA certificate for clients ----------
platform_user="$(invoking_user)"
install -d -m 0755 "$OUT_DIR"
chown "$platform_user": "$OUT_DIR" 2>/dev/null || true
platform_ca="$(kc -n cert-manager get secret platform-ca -o jsonpath='{.data.tls\.crt}')"
[[ -n "$platform_ca" ]] || die "secret cert-manager/platform-ca has no tls.crt"
write_file "$OUT_DIR/ca.crt" 0644 < <(base64 -d <<<"$platform_ca")  # no pipe: keeps ok/changed counters
chown "$platform_user": "$OUT_DIR/ca.crt" 2>/dev/null || true
info "CA for clients: $OUT_DIR/ca.crt (curl --cacert $OUT_DIR/ca.crt https://${APP_HOST}/)"
