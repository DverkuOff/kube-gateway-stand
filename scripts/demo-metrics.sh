#!/usr/bin/env bash
# Sends demo traffic through the Gateway and shows what Prometheus collected, with the PromQL used.
# Runs as a regular user (no sudo) with ~/.kube/config written by the deployment.
#
#   ./scripts/demo-metrics.sh            # ~200 requests, then queries
#   REQUESTS=400 ./scripts/demo-metrics.sh
#   SKIP_TRAFFIC=1 ./scripts/demo-metrics.sh   # queries only
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA="$REPO_ROOT/out/ca.crt"
REQUESTS="${REQUESTS:-200}"
PROM_PROXY="/api/v1/namespaces/monitoring/services/kps-prometheus:http-web/proxy"
SVC='.*-svc-web-web-v[12]-[0-9]+@kubernetesgateway'
SVC_V2='.*-svc-web-web-v2-[0-9]+@kubernetesgateway'

b=''; c=''; n=''
if [[ -t 1 ]]; then b=$'\e[1m'; c=$'\e[36m'; n=$'\e[0m'; fi
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
title() { printf '\n%s==> %s%s\n' "$b" "$*" "$n"; }

for tool in kubectl curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
kubectl get --raw /readyz --request-timeout=5s >/dev/null 2>&1 \
  || die "cannot reach the cluster with ${KUBECONFIG:-$HOME/.kube/config}; run sudo ./deploy.sh (it writes the kubeconfig for your user)"
kubectl -n monitoring get service kps-prometheus >/dev/null 2>&1 \
  || die "Prometheus (monitoring/kps-prometheus) not found; run stage 50-monitoring"

# promql QUERY -> raw JSON result vector, queried through the API server service proxy
promql() {
  local q enc
  q=$1
  enc="$(jq -rn --arg q "$q" '$q | @uri')"
  kubectl get --raw "${PROM_PROXY}/api/v1/query?query=${enc}" | jq -c '.data.result'
}
show() {  # show QUERY JQ_FORMAT
  printf '  %sPromQL:%s %s\n' "$c" "$n" "$1"
  local out
  out="$(promql "$1" | jq -r "if length == 0 then \"  (no data yet)\" else .[] | $2 end")"
  printf '%s\n' "$out"
}

# ---------- traffic ----------
if [[ -z "${SKIP_TRAFFIC:-}" ]]; then
  [[ -f "$CA" ]] || die "$CA not found (stage 30-platform exports the cluster CA there)"
  node_ip="$(kubectl -n gateway get gateway web -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  [[ -n "$node_ip" ]] || die "Gateway gateway/web has no address in its status; check: kubectl -n gateway describe gateway web"
  app_host="${APP_HOST:-$(kubectl -n web get httproute -o jsonpath='{.items[0].spec.hostnames[0]}' 2>/dev/null || true)}"
  app_host="${app_host:-app.${node_ip}.sslip.io}"

  req() {  # req PATH [curl args...] -> prints the status code
    local path=$1
    shift
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 --cacert "$CA" \
      --resolve "${app_host}:443:${node_ip}" "$@" "https://${app_host}${path}" || echo 000
  }

  # Gateway counter of the app backends before the demo traffic: the wait below needs the
  # samples of this run, not the ones of earlier traffic.
  total_q="sum(traefik_service_requests_total{service=~\"${SVC}\"})"
  total_before="$(promql "$total_q" | jq -r '.[0].value[1] // "0"')"

  paced=$((REQUESTS * 3 / 5))
  burst=$((REQUESTS - paced))
  title "Sending ${paced} paced requests to https://${app_host} (via ${node_ip}): /, X-Version: v2, ?version=v2, /preview, a missing page"
  paced_codes="$(
    for ((i = 1; i <= paced; i++)); do
      case $((i % 10)) in
        1) req / -H 'X-Version: v2' ;;
        2) req '/?version=v2' ;;
        3) req /preview ;;
        4) req /no-such-page ;;
        *) req / ;;
      esac
      sleep 0.06   # stay under the rate limit (20 rps)
    done
  )"
  printf '%s\n' "$paced_codes" | sort | uniq -c | awk '{printf "    HTTP %s: %s\n", $2, $1}'

  title "Sending a burst of ${burst} parallel requests to trigger the rate limit (429)"
  export -f req
  export CA app_host node_ip
  burst_codes="$(seq "$burst" | xargs -P 20 -I{} bash -c 'req /')"
  printf '%s\n' "$burst_codes" | sort | uniq -c | awk '{printf "    HTTP %s: %s\n", $2, $1}'

  # Requests that reached a backend (429 is answered by the gateway itself, 000 is a client error).
  reached="$(printf '%s\n' "$paced_codes" "$burst_codes" | grep -cvE '^(429|000)$' || true)"
  total_want="$(awk -v b="$total_before" -v r="$reached" 'BEGIN { print b + r }')"
  title "Waiting for Prometheus to scrape the new samples (gateway counter ${total_before} -> ${total_want})"
  deadline=$((SECONDS + ${SCRAPE_WAIT:-150}))
  until awk -v now="$(promql "$total_q" | jq -r '.[0].value[1] // "0"')" -v want="$total_want" 'BEGIN { exit !(now >= want) }'; do
    if ((SECONDS >= deadline)); then
      printf '  not all samples yet; Prometheus scrapes every 30-60 s, re-run with SKIP_TRAFFIC=1 in a minute\n'
      break
    fi
    sleep 5
  done
fi

# ---------- queries ----------
title "Healthy scrape targets by job"
show 'count by (job) (up == 1)' '"    \(.metric.job // "-"): \(.value[1])"'
down="$(promql 'up == 0' | jq -r '.[] | "    DOWN \(.metric.job) \(.metric.instance)"')"
[[ -z "$down" ]] || printf '%s\n' "$down"

# Request counts are read from the counters themselves (totals since the gateway started), not
# with increase(): on a fresh cluster a series that appears during the demo traffic has a single
# sample, and increase()/rate() would miss it. The Grafana dashboard shows the rates over time.
title "Requests through the gateway by status code (counters since the gateway started)"
show "sum by (code) (traefik_service_requests_total{service=~\"${SVC}\"})" \
  '"    HTTP \(.metric.code): \(.value[1])"'

title "Requests by version (counters since the gateway started)"
show "sum by (version) (label_replace(traefik_service_requests_total{service=~\"${SVC}\"}, \"version\", \"\$1\", \"service\", \".*-svc-web-web-(v[12])-.*\"))" \
  '"    \(.metric.version): \(.value[1])"'

title "Share of v2 among all requests (includes the X-Version, ?version and /preview requests pinned to v2)"
show "sum(traefik_service_requests_total{service=~\"${SVC_V2}\"}) / sum(traefik_service_requests_total{service=~\"${SVC}\"})" \
  '"    \(if .value[1] == "NaN" then "n/a" else "\((.value[1] | tonumber) * 100 | floor)%" end) of requests went to v2"'

# Traefik names the router of an HTTPRoute rule after the rule index:
#   httproute-<ns>-<route>-gw-<gw-ns>-<gw>-ep-<entrypoint>-<rule index>-<hash>
# so the weighted rule "canary" can be measured on its own.
canary_idx="$(kubectl -n web get httproute web -o json 2>/dev/null | jq -r '[.spec.rules[].name] | index("canary") // empty' || true)"
canary_w="$(kubectl -n web get httproute web -o json 2>/dev/null | jq -r '[.spec.rules[] | select(.name == "canary") | .backendRefs[] | select(.name == "web-v2") | .weight][0] // empty' || true)"
if [[ -n "$canary_idx" ]]; then
  rule_re="httproute-web-web-gw-gateway-web-ep-websecure-${canary_idx}-[0-9a-f]+-svc-web-web"
  title "Weighted split of the rule \"canary\" (\"/\" without pins; v2 weight in the HTTPRoute: ${canary_w:-?}%)"
  show "sum(traefik_service_requests_total{service=~\"${rule_re}-v2-[0-9]+@kubernetesgateway\"}) / sum(traefik_service_requests_total{service=~\"${rule_re}-v[12]-[0-9]+@kubernetesgateway\"})" \
    '"    \(if .value[1] == "NaN" then "n/a" else "\((.value[1] | tonumber) * 1000 | round / 10)%" end) of the weighted requests went to v2"'
fi

title "p95 latency by version (last 5 min)"
show "histogram_quantile(0.95, sum by (le, version) (label_replace(rate(traefik_service_request_duration_seconds_bucket{service=~\"${SVC}\"}[5m]), \"version\", \"\$1\", \"service\", \".*-svc-web-web-(v[12])-.*\")))" \
  '"    \(.metric.version): \(if .value[1] == "NaN" then "n/a" else "\((.value[1] | tonumber) * 1000 | floor) ms" end)"'

# 429 never reaches a backend: it is counted on the entry point.
title "Rejected by the rate limit, HTTP 429 (counter since the gateway started)"
show 'sum(traefik_entrypoint_requests_total{entrypoint="websecure",code="429"})' \
  '"    429 responses: \(.value[1])"'

printf '\nThe same queries are on the Grafana dashboard "Web: golden signals" (./scripts/creds.sh shows the URL and login).\n'
