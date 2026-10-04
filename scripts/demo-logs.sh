#!/usr/bin/env bash
# demo-logs — shows that a request to the app ends up in Loki within seconds.
#
#   1. GET https://APP_HOST/ through the gateway with a unique X-Request-ID;
#   2. GET a missing path with the same id (404 -> a line in the nginx error log);
#   3. queries Loki through the API server (no port-forward) and prints the gateway access
#      line, the app access line and the error line.
#
# Runs without sudo, with the user's kubeconfig (~/.kube/config, written by deploy.sh).
# Overrides: KUBECONFIG, NODE_IP, APP_HOST, GRAFANA_HOST, WAIT_SECONDS (default 30).
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
WAIT_SECONDS="${WAIT_SECONDS:-30}"
LOKI_PROXY="/api/v1/namespaces/logging/services/loki:3100/proxy"
CA="$REPO_ROOT/out/ca.crt"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

for tool in kubectl curl jq; do
  have "$tool" || die "$tool is not installed"
done
[[ -r "$KUBECONFIG" ]] || die "kubeconfig $KUBECONFIG is not readable (deploy.sh writes ~/.kube/config for the user who ran it; or set KUBECONFIG)"
kubectl version --request-timeout=10s >/dev/null 2>&1 || die "cannot reach the cluster with $KUBECONFIG"
[[ -r "$CA" ]] || die "$CA not found: run ./deploy.sh first (it exports the cluster CA there)"

# Gateway address and app hostname: environment, else what the cluster reports.
NODE_IP="${NODE_IP:-$(kubectl -n gateway get gateway web -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)}"
[[ -n "$NODE_IP" ]] || die "cannot find the gateway address (kubectl -n gateway get gateway web); set NODE_IP"
APP_HOST="${APP_HOST:-app.${NODE_IP}.sslip.io}"
GRAFANA_HOST="${GRAFANA_HOST:-grafana.${NODE_IP}.sslip.io}"

loki_get() {  # loki_get PATH_AND_QUERY -> JSON from Loki via the API server's service proxy
  kubectl get --raw "${LOKI_PROXY}$1"
}
loki_get "/ready" 2>/dev/null | grep -q '^ready' || die "Loki is not ready (kubectl -n logging get pods)"

rid="demo-$(date +%s)-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
start_ns="$(( ($(date +%s) - 60) * 1000000000 ))"
curl_app() {  # curl_app PATH -> HTTP status
  curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    --cacert "$CA" --resolve "${APP_HOST}:443:${NODE_IP}" \
    -H "X-Request-ID: ${rid}" "https://${APP_HOST}$1"
}

printf '==> Request id: %s\n' "$rid"
code="$(curl_app /)" || die "request to https://${APP_HOST}/ failed"
printf '    GET https://%s/                 -> %s\n' "$APP_HOST" "$code"
missing="/missing-${rid}"
code="$(curl_app "$missing")" || die "request to https://${APP_HOST}${missing} failed"
printf '    GET https://%s%s -> %s (expected 404, logged by nginx as an error)\n' "$APP_HOST" "$missing" "$code"

query="{namespace=~\"web|gateway\"} |= \"${rid}\""
query_enc="$(jq -rn --arg q "$query" '$q | @uri')"

printf '==> Waiting up to %ss for the lines in Loki: %s\n' "$WAIT_SECONDS" "$query"
deadline=$((SECONDS + WAIT_SECONDS))
result=''
while :; do
  result="$(loki_get "/loki/api/v1/query_range?query=${query_enc}&start=${start_ns}&limit=100&direction=forward" 2>/dev/null || true)"
  [[ -n "$result" ]] || result='{}'
  have_gw="$(jq -r '[.data.result[]? | select(.stream.namespace=="gateway" and .stream.log_type=="access")] | length' <<<"$result")"
  have_app="$(jq -r '[.data.result[]? | select(.stream.namespace=="web" and .stream.log_type=="access")] | length' <<<"$result")"
  have_err="$(jq -r '[.data.result[]? | select(.stream.namespace=="web" and .stream.log_type=="error")] | length' <<<"$result")"
  if [[ "$have_gw" -gt 0 && "$have_app" -gt 0 && "$have_err" -gt 0 ]] || ((SECONDS >= deadline)); then
    break
  fi
  sleep 2
done

printf '==> Lines found in Loki\n'
jq -r '
  [.data.result[]? | .stream as $s | .values[] | {ts: .[0], s: $s, line: .[1]}]
  | sort_by(.ts)[]
  | "  [\(.s.namespace)/\(.s.container) \(.s.log_type) \(.s.stream)] \(.line)"
' <<<"$result"

status() { if [[ "$1" -gt 0 ]]; then printf 'found'; else printf 'MISSING'; fi; }
printf '\n    gateway access log: %s\n' "$(status "$have_gw")"
printf '    app access log:     %s\n' "$(status "$have_app")"
printf '    app error log:      %s\n' "$(status "$have_err")"

cat <<EOF

==> The same in Grafana (https://${GRAFANA_HOST}/explore, datasource Loki):
    {namespace=~"web|gateway"} |= "${rid}"
    {namespace="web", log_type="access"} | json | status >= 400
    {namespace="web", log_type="error"}
    sum by (namespace, log_type) (count_over_time({namespace=~".+"}[5m]))
EOF

[[ "$have_app" -gt 0 && "$have_err" -gt 0 ]] || die "the app lines did not reach Loki within ${WAIT_SECONDS}s (kubectl -n logging logs ds/fluentd)"
