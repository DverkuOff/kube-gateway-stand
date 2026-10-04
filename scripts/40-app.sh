#!/usr/bin/env bash
# Stage 40-app — demo web app v1/v2 and its HTTPRoutes
# Owner: track B. Sourced by deploy.sh; can also run alone: sudo ./scripts/40-app.sh
#   CANARY_WEIGHT=0..100  share of "/" traffic sent to v2 (default 20)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_standalone_init

app_weight="${CANARY_WEIGHT:-20}"
if ! [[ "$app_weight" =~ ^[0-9]+$ ]] || ((10#$app_weight > 100)); then
  die "CANARY_WEIGHT must be an integer 0..100, got '${app_weight}'"
fi
app_weight=$((10#$app_weight))
kc get namespace web >/dev/null 2>&1 \
  || die "namespace 'web' not found: run stage 30-platform first (sudo ./deploy.sh)"

step "web app v1/v2 (canary weight v2=${app_weight}%)"
app_args=(
  --set "host=${APP_HOST}"
  --set "canary.weight=${app_weight}"
  --set "nginx.image=${NGINX_IMAGE}"
  --set "exporter.image=${NGINX_EXPORTER_IMAGE}"
  # kubelet probes come from the node address
  --set "networkPolicy.nodeCIDRs={${NODE_IP}/32}"
  # scripts/canary.sh patches the route weights; the deploy is the source of truth and takes them back
  --force-conflicts
)
[[ "$PROFILE" == small ]] && app_args+=(-f "$REPO_ROOT/charts/web/values-small.yaml")
helm_release web web "$REPO_ROOT/charts/web" "" "${app_args[@]}"

# shellcheck disable=SC2329  # invoked indirectly through wait_for
app_route_ready() {
  kc -n web get httproute web -o json | jq -e '
    [.status.parents[]? | select(.parentRef.name == "web") | .conditions[]?
     | select((.type == "Accepted" or .type == "ResolvedRefs") and .status == "True")] | length >= 2' >/dev/null
}
wait_for 120 "HTTPRoute web/web Accepted with resolved backends" app_route_ready
ok "HTTPRoute web Accepted, backends resolved"

# Smoke test through the gateway with TLS verification against our CA.
app_ca="$OUT_DIR/ca.crt"
[[ -s "$app_ca" ]] || die "$app_ca is missing: run stage 30-platform first"
app_body=""
# shellcheck disable=SC2329  # invoked indirectly through retry
app_probe() {
  app_body="$(curl -fsS --max-time 5 --cacert "$app_ca" --resolve "${APP_HOST}:443:${NODE_IP}" "https://${APP_HOST}/" 2>/dev/null)" \
    && [[ "$app_body" == "Hello World!"* ]]
}
if retry 20 3 app_probe; then
  ok "https://${APP_HOST}/ -> ${app_body}"
else
  die "https://${APP_HOST}/ does not answer 'Hello World!' via ${NODE_IP}:443 (kubectl -n web get httproute web -o yaml; kubectl -n gateway logs deploy/traefik)"
fi
