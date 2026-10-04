#!/usr/bin/env bash
# make check — end-to-end smoke test of the whole deployment.
#
# Runs as a regular user (no sudo) with kubectl and the user's kubeconfig (~/.kube/config, written
# by stage 20) or $KUBECONFIG. Everything is read from the cluster: the node address from the status
# of Gateway web, host names from the HTTPRoutes, the CA from out/ca.crt.
# Prints numbered PASS/FAIL/SKIP lines and "N passed, M failed"; exits non-zero when anything fails.
#
# Optional environment: PROM_SVC (default kps-prometheus:http-web), LOKI_SVC (default loki:3100),
# SPLIT_REQUESTS (200), BURST_REQUESTS (100), LOG_TIMEOUT (30).
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
# shellcheck source=../versions.env
source "$REPO_ROOT/versions.env"

PROM_SVC="${PROM_SVC:-kps-prometheus:http-web}"
LOKI_SVC="${LOKI_SVC:-loki:3100}"
PROM_API="/api/v1/namespaces/monitoring/services/${PROM_SVC}/proxy/api/v1"
LOKI_API="/api/v1/namespaces/logging/services/${LOKI_SVC}/proxy/loki/api/v1"
SPLIT_REQUESTS="${SPLIT_REQUESTS:-200}"
BURST_REQUESTS="${BURST_REQUESTS:-100}"
LOG_TIMEOUT="${LOG_TIMEOUT:-30}"
SPLIT_TOLERANCE=8 # percentage points

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------- prerequisites (fail early with a clear message, not a stack trace) ----------
for bin in kubectl curl jq; do
  have "$bin" || die "'$bin' is not installed. It is installed by sudo ./deploy.sh; on another machine install it first."
done

if [[ -n "${KUBECONFIG:-}" ]]; then
  IFS=: read -ra kcfgs <<<"$KUBECONFIG"
  for f in "${kcfgs[@]}"; do
    [[ -r "$f" ]] || die "KUBECONFIG points to '$f', which does not exist or is not readable."
  done
elif [[ -r "$HOME/.kube/config" ]]; then
  :
elif [[ $EUID -eq 0 && -r /etc/kubernetes/admin.conf ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
else
  die "no readable kubeconfig: $HOME/.kube/config is missing or not readable.
       Deploy first (make deploy copies it for the invoking user) or set KUBECONFIG=/path/to/config."
fi

k() { kubectl --request-timeout=20s "$@"; }

if ! k get --raw /readyz >/dev/null 2>"$TMP/err"; then
  die "cannot reach the Kubernetes API server: $(head -c 300 "$TMP/err")
       Is the cluster deployed and running? Try: kubectl get nodes"
fi

# ---------- reporting ----------
PASSED=0 FAILED=0 SKIPPED=0 MSG=""
section() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; }

# check ID TITLE FUNCTION — FUNCTION returns 0 (pass), 1 (fail) or 2 (skip) and sets MSG.
check() {
  local id=$1 title=$2 fn=$3 rc=0
  MSG=""
  "$fn" || rc=$?
  case $rc in
    0) PASSED=$((PASSED + 1)); printf '  %-5s %sPASS%s  %s\n' "$id" "$C_G" "$C_0" "$title" ;;
    2) SKIPPED=$((SKIPPED + 1)); printf '  %-5s %sSKIP%s  %s\n' "$id" "$C_Y" "$C_0" "$title" ;;
    *) FAILED=$((FAILED + 1)); printf '  %-5s %sFAIL%s  %s\n' "$id" "$C_R" "$C_0" "$title" ;;
  esac
  if [[ -n "$MSG" ]]; then
    printf '%s\n' "$MSG" | sed 's/^/              /'
  fi
  return 0
}

# ---------- helpers ----------
uri() { jq -rn --arg v "$1" '$v|@uri'; }

# prom QUERY — prints the JSON result of an instant query through the API server proxy.
prom() { k get --raw "${PROM_API}/query?query=$(uri "$1")"; }

# prom_scalar QUERY — prints the first sample value, or nothing.
prom_scalar() { prom "$1" 2>/dev/null | jq -r '.data.result[0].value[1] // empty' 2>/dev/null; }

curl_tls() {
  curl -sS --max-time 15 --cacert "$CA" --resolve "${APP_HOST}:443:${NODE_IP}" "$@"
}

curl_error() {
  case $1 in
    6) echo "could not resolve host" ;;
    7) echo "connection refused" ;;
    28) echo "timeout" ;;
    35) echo "TLS handshake failed" ;;
    60) echo "certificate not trusted by the CA ($CA)" ;;
    *) echo "curl exit code $1" ;;
  esac
}

need_http() {
  if [[ -z "$NODE_IP" ]]; then MSG="node address is unknown (see 2.2)"; return 1; fi
  if [[ -z "$CA" ]]; then MSG="no CA certificate (see 3.2)"; return 1; fi
  return 0
}

# hit_many N PATH [curl args] — N sequential requests over one connection (rate-limited to stay under
# the gateway rate limit). Prints bodies, each followed by "CODE:<status>".
hit_many() {
  local n=$1 path=$2 urls=() i
  shift 2
  for ((i = 0; i < n; i++)); do urls+=("https://${APP_HOST}${path}"); done
  if curl --help all 2>/dev/null | grep -q -- '--rate'; then
    curl_tls --rate 12/s -w '\nCODE:%{http_code}\n' "$@" "${urls[@]}" 2>/dev/null || true
  else
    for ((i = 0; i < n; i++)); do
      curl_tls -w '\nCODE:%{http_code}\n' "$@" "https://${APP_HOST}${path}" 2>/dev/null || true
      sleep 0.08
    done
  fi
}

# ---------- discovery ----------
NODES_JSON="$(k get nodes -o json 2>/dev/null || echo '{"items":[]}')"
NODE_INTERNAL_IP="$(jq -r '[.items[0].status.addresses[]? | select(.type=="InternalIP") | .address][0] // empty' <<<"$NODES_JSON")"
NODE_IP="$(k get gateways.gateway.networking.k8s.io web -n gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
NODE_IP_NOTE=""
if [[ -z "$NODE_IP" && -n "$NODE_INTERNAL_IP" ]]; then
  NODE_IP="$NODE_INTERNAL_IP"
  NODE_IP_NOTE=" (Gateway web has no address; using the node InternalIP)"
fi
ROUTES_JSON="$(k get httproutes.gateway.networking.k8s.io -A -o json 2>/dev/null || echo '{"items":[]}')"
APP_HOST="$(jq -r '[.items[] | select(.metadata.namespace=="web") | .spec.hostnames[]?][0] // empty' <<<"$ROUTES_JSON")"
GRAFANA_HOST="$(jq -r '[.items[] | select(.metadata.namespace=="monitoring") | .spec.hostnames[]?][0] // empty' <<<"$ROUTES_JSON")"
[[ -z "$APP_HOST" && -n "$NODE_IP" ]] && APP_HOST="app.${NODE_IP}.sslip.io"

CA=""
CA_NOTE=""
if [[ -r "$REPO_ROOT/out/ca.crt" ]]; then
  CA="$REPO_ROOT/out/ca.crt"
elif k get secret web-tls -n gateway -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d >"$TMP/ca.crt" 2>/dev/null && [[ -s "$TMP/ca.crt" ]]; then
  CA="$TMP/ca.crt"
  CA_NOTE=" (out/ca.crt not found; CA taken from secret gateway/web-tls)"
fi

printf '%sCluster checks%s  node=%s%s  app=%s  grafana=%s\n' "$C_B" "$C_0" \
  "${NODE_IP:-?}" "$NODE_IP_NOTE" "${APP_HOST:-?}" "${GRAFANA_HOST:-?}"

# Baseline of the gateway request counter, used by 7.3 (taken before any test traffic).
TRAEFIK_REQ_QUERY='sum(traefik_service_requests_total)'
TRAEFIK_BASELINE="$(prom_scalar "$TRAEFIK_REQ_QUERY" || true)"

# =====================================================================================
# 1. Cluster
# =====================================================================================
c_node() {
  local n bad
  n="$(jq '.items | length' <<<"$NODES_JSON")"
  ((n > 0)) || { MSG="no nodes returned by the API server"; return 1; }
  MSG="$(jq -r '.items[] | "\(.metadata.name): Ready=\([.status.conditions[] | select(.type=="Ready") | .status][0]), kubelet \(.status.nodeInfo.kubeletVersion), \(.status.nodeInfo.osImage), \(.status.nodeInfo.containerRuntimeVersion)"' <<<"$NODES_JSON")"
  bad="$(jq -r --arg v "$KUBERNETES_VERSION" '.items[] | select(([.status.conditions[] | select(.type=="Ready" and .status=="True")] | length) == 0 or .status.nodeInfo.kubeletVersion != $v) | .metadata.name' <<<"$NODES_JSON")"
  if [[ -n "$bad" ]]; then
    MSG+=$'\n'"expected Ready and kubelet $KUBERNETES_VERSION (versions.env)"
    return 1
  fi
}

c_pods() {
  local pods total bad
  pods="$(k get pods -A -o json 2>/dev/null)" || { MSG="kubectl get pods failed"; return 1; }
  total="$(jq '[.items[] | select(.status.phase != "Succeeded")] | length' <<<"$pods")"
  bad="$(jq -r '.items[] | select(.status.phase != "Succeeded")
      | select(([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length) == 0)
      | "\(.metadata.namespace)/\(.metadata.name) (\(.status.phase)\([.status.containerStatuses[]?.state.waiting.reason // empty] | if length > 0 then ", " + join(",") else "" end))"' <<<"$pods")"
  if [[ -n "$bad" ]]; then
    MSG="not ready:"$'\n'"$bad"
    return 1
  fi
  MSG="$total pods Ready"
}

c_helm() {
  local list problems="" r ns name st
  have helm || { MSG="helm is not installed for this user"; return 2; }
  list="$(helm list -A -a -o json 2>"$TMP/err")" || { MSG="helm list failed: $(head -c 200 "$TMP/err")"; return 2; }
  for r in tigera-operator/calico cert-manager/cert-manager gateway/traefik gateway/platform web/web \
    monitoring/kps monitoring/observability logging/loki logging/fluentd; do
    ns=${r%/*} name=${r#*/}
    st="$(jq -r --arg n "$name" --arg ns "$ns" '.[] | select(.name==$n and .namespace==$ns) | .status' <<<"$list")"
    [[ "$st" == "deployed" ]] || problems+="$r: ${st:-not installed}"$'\n'
  done
  MSG="$(jq -r '.[] | "\(.namespace)/\(.name) rev \(.revision) \(.status) \(.chart)"' <<<"$list")"
  if [[ -n "$problems" ]]; then
    MSG+=$'\n'"problems:"$'\n'"${problems%$'\n'}"
    return 1
  fi
}

# =====================================================================================
# 2. Gateway API
# =====================================================================================
c_gatewayclass() {
  local st ctrl
  st="$(k get gatewayclasses.gateway.networking.k8s.io traefik -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  ctrl="$(k get gatewayclasses.gateway.networking.k8s.io traefik -o jsonpath='{.spec.controllerName}' 2>/dev/null || true)"
  MSG="controller ${ctrl:-?}, Accepted=${st:-missing}"
  [[ "$st" == "True" ]]
}

c_gateway() {
  local prog addr
  prog="$(k get gateways.gateway.networking.k8s.io web -n gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  addr="$(k get gateways.gateway.networking.k8s.io web -n gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  MSG="Programmed=${prog:-missing}, address=${addr:-none}, node InternalIP=${NODE_INTERNAL_IP:-?}"
  [[ "$prog" == "True" && -n "$addr" && "$addr" == "$NODE_INTERNAL_IP" ]]
}

c_routes() {
  local n bad
  n="$(jq '.items | length' <<<"$ROUTES_JSON")"
  ((n > 0)) || { MSG="no HTTPRoutes found"; return 1; }
  bad="$(jq -r '.items[] | . as $r
      | ([.status.parents[]?.conditions[]? | select((.type=="Accepted" or .type=="ResolvedRefs") and .status=="True") | .type] | unique) as $ok
      | select(($ok | length) < 2)
      | "\($r.metadata.namespace)/\($r.metadata.name): \([.status.parents[]?.conditions[]? | "\(.type)=\(.status) \(.reason)"] | join(", ") | if . == "" then "no status" else . end)"' <<<"$ROUTES_JSON")"
  MSG="$(jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) \(.spec.hostnames // ["*"] | join(","))"' <<<"$ROUTES_JSON")"
  if [[ -n "$bad" ]]; then
    MSG+=$'\n'"not Accepted/ResolvedRefs:"$'\n'"$bad"
    return 1
  fi
}

# =====================================================================================
# 3. HTTP, TLS, application
# =====================================================================================
c_redirect() {
  local out rc=0 code loc
  [[ -n "$NODE_IP" ]] || { MSG="node address is unknown (see 2.2)"; return 1; }
  out="$(curl -sS -o /dev/null --max-time 10 -w '%{http_code} %{redirect_url}' "http://${NODE_IP}/" 2>/dev/null)" || rc=$?
  ((rc == 0)) || { MSG="http://${NODE_IP}/: $(curl_error "$rc")"; return 1; }
  code=${out%% *} loc=${out#* }
  MSG="http://${NODE_IP}/ -> $code ${loc}"
  [[ "$code" == "301" && "$loc" == https://* ]]
}

c_app() {
  local code rc=0
  [[ -n "$NODE_IP" ]] || { MSG="node address is unknown (see 2.2)"; return 1; }
  [[ -n "$CA" ]] || { MSG="CA not found: $REPO_ROOT/out/ca.crt is missing and secret gateway/web-tls has no ca.crt"; return 1; }
  code="$(curl_tls -o "$TMP/body" -w '%{http_code}' "https://${APP_HOST}/" 2>/dev/null)" || rc=$?
  ((rc == 0)) || { MSG="https://${APP_HOST}/: $(curl_error "$rc")"; return 1; }
  MSG="https://${APP_HOST}/ -> $code \"$(head -c 80 "$TMP/body" | tr -d '\r\n')\", certificate verified with ${CA}${CA_NOTE}"
  [[ "$code" == "200" ]] && grep -q 'Hello World!' "$TMP/body"
}

# =====================================================================================
# 4. Routing
# =====================================================================================
# route_v2 DESCRIPTION PATH [curl args] — 5 requests, all must be answered by v2.
route_v2() {
  local desc=$1 path=$2 out v2 total
  shift 2
  need_http || return 1
  out="$(hit_many 5 "$path" "$@")"
  v2="$(grep -c 'Hello World! (v2)' <<<"$out" || true)"
  total="$(grep -c '^CODE:' <<<"$out" || true)"
  MSG="$desc: $v2 of 5 answered by v2 (codes: $(grep '^CODE:' <<<"$out" | cut -d: -f2 | sort | uniq -c | xargs))"
  ((total == 5 && v2 == 5))
}
c_route_header() { route_v2 "header X-Version: v2" / -H 'X-Version: v2'; }
c_route_query() { route_v2 "query ?version=v2" '/?version=v2'; }
c_route_path() { route_v2 "path /preview" /preview; }

c_split() {
  local weight out v1 v2 other share lo hi
  need_http || return 1
  weight="$(jq -r '[.items[] | select(.metadata.namespace=="web") | .spec.rules[]? | select((.backendRefs // []) | length >= 2) | .backendRefs][0]
      | select(. != null) | ((map(select(.name=="web-v2") | (.weight // 1)) | add // 0) * 100 / (map(.weight // 1) | add))' <<<"$ROUTES_JSON")"
  [[ -n "$weight" ]] || { MSG="no HTTPRoute rule in ns web with two weighted backends"; return 1; }
  out="$(hit_many "$SPLIT_REQUESTS" /)"
  v1="$(grep -c 'Hello World! (v1)' <<<"$out" || true)"
  v2="$(grep -c 'Hello World! (v2)' <<<"$out" || true)"
  other=$((SPLIT_REQUESTS - v1 - v2))
  ((v1 + v2 > 0)) || { MSG="no successful answers (codes: $(grep '^CODE:' <<<"$out" | cut -d: -f2 | sort | uniq -c | xargs))"; return 1; }
  share="$(awk -v a="$v2" -v b="$((v1 + v2))" 'BEGIN { printf "%.1f", a * 100 / b }')"
  lo="$(awk -v w="$weight" -v t="$SPLIT_TOLERANCE" 'BEGIN { print w - t }')"
  hi="$(awk -v w="$weight" -v t="$SPLIT_TOLERANCE" 'BEGIN { print w + t }')"
  MSG="weight of v2 in HTTPRoute: ${weight}%; measured: v1=$v1 v2=$v2 other=$other -> v2 share ${share}% (allowed ${lo}..${hi})"
  awk -v s="$share" -v lo="$lo" -v hi="$hi" 'BEGIN { exit !(s >= lo && s <= hi) }'
}

# =====================================================================================
# 5. Rate limit
# =====================================================================================
c_ratelimit() {
  local urls=() i out n429 n200 code rc=0
  need_http || return 1
  for ((i = 0; i < BURST_REQUESTS; i++)); do urls+=("https://${APP_HOST}/"); done
  out="$(curl_tls --parallel --parallel-immediate --parallel-max "$BURST_REQUESTS" \
    -w '\nCODE:%{http_code}\n' "${urls[@]}" 2>/dev/null || true)"
  n429="$(grep -c '^CODE:429' <<<"$out" || true)"
  n200="$(grep -c '^CODE:200' <<<"$out" || true)"
  sleep 3
  code="$(curl_tls -o /dev/null -w '%{http_code}' "https://${APP_HOST}/" 2>/dev/null)" || rc=$?
  MSG="burst of $BURST_REQUESTS parallel requests: 200=$n200 429=$n429; after 3 s pause: ${code:-error $rc}"
  ((n429 > 0 && n200 > 0)) && [[ "$code" == "200" ]]
}

# =====================================================================================
# 6. Errors
# =====================================================================================
c_404() {
  local code rc=0 path="/no-such-page-$RANDOM"
  need_http || return 1
  code="$(curl_tls -o /dev/null -w '%{http_code}' "https://${APP_HOST}${path}" 2>/dev/null)" || rc=$?
  ((rc == 0)) || { MSG="$(curl_error "$rc")"; return 1; }
  MSG="https://${APP_HOST}${path} -> $code"
  [[ "$code" == "404" ]]
}

# =====================================================================================
# 7. Metrics (Prometheus through the API server proxy)
# =====================================================================================
UP_JSON=""
c_targets() {
  local total up down
  UP_JSON="$(prom 'up' 2>"$TMP/err")" || {
    MSG="Prometheus API not reachable via services/${PROM_SVC} in ns monitoring: $(head -c 200 "$TMP/err")"
    UP_JSON=""
    return 1
  }
  total="$(jq '.data.result | length' <<<"$UP_JSON")"
  up="$(jq '[.data.result[] | select(.value[1]=="1")] | length' <<<"$UP_JSON")"
  down="$(jq -r '.data.result[] | select(.value[1]!="1") | "down: \(.metric.job) \(.metric.instance)"' <<<"$UP_JSON")"
  MSG="targets up: $up of $total"${down:+$'\n'"$down"}
  ((total > 0 && up == total))
}

c_jobs() {
  local spec name field re found problems="" summary=""
  [[ -n "$UP_JSON" ]] || { MSG="no data from Prometheus (see 7.1)"; return 1; }
  # name|label|regex — a component counts as present when it has a target and all its targets are up.
  for spec in \
    'traefik|job|traefik' 'node-exporter|job|node-exporter' 'kubelet|job|^kubelet$' \
    'apiserver|job|^apiserver$' 'kube-state-metrics|job|kube-state-metrics' 'coredns|job|coredns' \
    'kube-scheduler|job|kube-scheduler' 'kube-controller-manager|job|kube-controller-manager' \
    'web (app exporter)|namespace|^web$' 'fluentd|job|fluentd' 'loki|job|loki' 'cert-manager|job|cert-manager'; do
    IFS='|' read -r name field re <<<"$spec"
    found="$(jq -r --arg f "$field" --arg re "$re" \
      '[.data.result[] | select((.metric[$f] // "") | test($re))] | "\([.[] | select(.value[1]=="1")] | length)/\(length)"' <<<"$UP_JSON")"
    summary+="$name $found, "
    if [[ "$found" == 0/0 ]]; then
      problems+="$name: no target"$'\n'
    elif [[ "${found%/*}" != "${found#*/}" ]]; then
      problems+="$name: only $found up"$'\n'
    fi
  done
  MSG="${summary%, }"
  if [[ -n "$problems" ]]; then
    MSG+=$'\n'"${problems%$'\n'}"
    return 1
  fi
}

c_traefik_counter() {
  local before after start
  need_http || return 1
  before="${TRAEFIK_BASELINE}"
  after="$(prom_scalar "$TRAEFIK_REQ_QUERY" || true)"
  [[ -n "$after" ]] || { MSG="metric traefik_service_requests_total not found in Prometheus"; return 1; }
  if [[ -z "$before" ]] || ! awk -v a="$after" -v b="$before" 'BEGIN { exit !(a > b) }'; then
    # Not grown yet (scrape interval): send a little more traffic and wait for the next scrape.
    before="$after"
    hit_many 10 / >/dev/null
    start=$SECONDS
    while ((SECONDS - start < 75)); do
      after="$(prom_scalar "$TRAEFIK_REQ_QUERY" || true)"
      awk -v a="${after:-0}" -v b="$before" 'BEGIN { exit !(a > b) }' && break
      sleep 5
    done
  fi
  MSG="$TRAEFIK_REQ_QUERY: ${before:-n/a} -> ${after:-n/a}"
  awk -v a="${after:-0}" -v b="${before:-0}" 'BEGIN { exit !(a > b) }'
}

# =====================================================================================
# 8. Logs (Loki through the API server proxy)
# =====================================================================================
LOG_GW="" LOG_WEB="" LOG_ERR="" LOG_RID=""
logs_probe() {
  local rid start now q res ns_found
  rid="check-$(date +%s)-$RANDOM$RANDOM"
  curl_tls -o /dev/null -H "X-Request-ID: $rid" "https://${APP_HOST}/" 2>/dev/null || true
  start=$SECONDS
  q="{namespace=~\"web|gateway\"} |= \"$rid\""
  while ((SECONDS - start <= LOG_TIMEOUT)); do
    now="$(date +%s)"
    if res="$(k get --raw "${LOKI_API}/query_range?query=$(uri "$q")&start=$((now - 600))000000000&end=$((now + 60))000000000&limit=50" 2>"$TMP/err")"; then
      ns_found="$(jq -r '[.data.result[]?.stream.namespace] | unique | join(" ")' <<<"$res" 2>/dev/null || true)"
      [[ -z "$LOG_GW" && " $ns_found " == *" gateway "* ]] && LOG_GW="$((SECONDS - start))"
      [[ -z "$LOG_WEB" && " $ns_found " == *" web "* ]] && LOG_WEB="$((SECONDS - start))"
      [[ -n "$LOG_GW" && -n "$LOG_WEB" ]] && break
    else
      LOG_ERR="Loki API not reachable via services/${LOKI_SVC} in ns logging: $(head -c 200 "$TMP/err")"
      break
    fi
    sleep 3
  done
  LOG_RID="$rid"
}
c_log_gateway() {
  need_http || return 1
  logs_probe
  [[ -z "$LOG_ERR" ]] || { MSG="$LOG_ERR"; return 1; }
  if [[ -n "$LOG_GW" ]]; then MSG="X-Request-ID $LOG_RID found in gateway logs after ${LOG_GW}s"; return 0; fi
  MSG="X-Request-ID $LOG_RID not found in {namespace=\"gateway\"} within ${LOG_TIMEOUT}s"
  return 1
}
c_log_app() {
  [[ -n "$LOG_RID" ]] || { MSG="no probe request (see 8.1)"; return 1; }
  [[ -z "$LOG_ERR" ]] || { MSG="$LOG_ERR"; return 1; }
  if [[ -n "$LOG_WEB" ]]; then MSG="X-Request-ID $LOG_RID found in application logs after ${LOG_WEB}s"; return 0; fi
  MSG="X-Request-ID $LOG_RID not found in {namespace=\"web\"} within ${LOG_TIMEOUT}s"
  return 1
}

# =====================================================================================
# 9. Security
# =====================================================================================
c_no_internal_routes() {
  local bad exposed
  bad="$(jq -r '.items[] | . as $r | .spec.rules[]?.backendRefs[]? | select(.name | test("prometheus|loki|alertmanager"))
      | "\($r.metadata.namespace)/\($r.metadata.name) -> \(.name)"' <<<"$ROUTES_JSON")"
  exposed="$(k get svc -n monitoring -o json 2>/dev/null | jq -r '.items[] | select(.spec.type=="NodePort" or .spec.type=="LoadBalancer") | "monitoring/\(.metadata.name) \(.spec.type)"')"
  exposed+="${exposed:+$'\n'}$(k get svc -n logging -o json 2>/dev/null | jq -r '.items[] | select(.spec.type=="NodePort" or .spec.type=="LoadBalancer") | "logging/\(.metadata.name) \(.spec.type)"')"
  if [[ -n "$bad$exposed" ]]; then
    MSG="exposed:"$'\n'"$bad"${exposed:+$'\n'"$exposed"}
    return 1
  fi
  MSG="Prometheus, Loki and Alertmanager have no HTTPRoute, NodePort or LoadBalancer"
}

c_grafana_auth() {
  local out rc=0 code loc
  need_http || return 1
  [[ -n "$GRAFANA_HOST" ]] || { MSG="no HTTPRoute with a hostname in ns monitoring"; return 1; }
  out="$(curl -sS --max-time 15 --cacert "$CA" --resolve "${GRAFANA_HOST}:443:${NODE_IP}" -o /dev/null \
    -w '%{http_code} %{redirect_url}' "https://${GRAFANA_HOST}/api/search" 2>/dev/null)" || rc=$?
  ((rc == 0)) || { MSG="https://${GRAFANA_HOST}/: $(curl_error "$rc")"; return 1; }
  code=${out%% *} loc=${out#* }
  MSG="anonymous GET https://${GRAFANA_HOST}/api/search -> $code ${loc}"
  [[ "$code" == "401" || ("$code" == "302" && "$loc" == */login*) ]]
}

c_psa() {
  local ns want got bad="" summary=""
  for ns in gateway:privileged web:restricted monitoring:privileged logging:privileged cert-manager:restricted; do
    want=${ns#*:} ns=${ns%:*}
    got="$(k get ns "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)"
    summary+="$ns=${got:-none} "
    [[ "$got" == "$want" ]] || bad+="$ns: enforce=${got:-none}, expected $want"$'\n'
  done
  MSG="enforce: ${summary% }"
  if [[ -n "$bad" ]]; then
    MSG+=$'\n'"${bad%$'\n'}"
    return 1
  fi
}

c_netpol() {
  local names
  names="$(k get networkpolicy -n web -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
  [[ -n "$names" ]] || { MSG="no NetworkPolicy in ns web"; return 1; }
  MSG="ns web: ${names% }"
}

# Passes when a TCP connection to NODE_IP:2381 is refused or times out.
c_etcd_port() {
  local rc=0
  [[ -n "$NODE_IP" ]] || { MSG="node address is unknown (see 2.2)"; return 1; }
  curl -s -o /dev/null --connect-timeout 3 --max-time 5 "http://${NODE_IP}:2381/metrics" 2>/dev/null || rc=$?
  case $rc in
    7 | 28) MSG="http://${NODE_IP}:2381 -> $(curl_error "$rc") (etcd metrics only on 127.0.0.1)"; return 0 ;;
    0) MSG="http://${NODE_IP}:2381/metrics answers without authentication" ;;
    *) MSG="http://${NODE_IP}:2381 accepts connections ($(curl_error "$rc"))" ;;
  esac
  return 1
}

c_node_exporter_port() {
  local rc=0
  [[ -n "$NODE_IP" ]] || { MSG="node address is unknown (see 2.2)"; return 1; }
  curl -s --connect-timeout 3 --max-time 5 -o "$TMP/ne" "http://${NODE_IP}:9100/metrics" 2>/dev/null || rc=$?
  if ((rc == 0)) && grep -q '^node_' "$TMP/ne" 2>/dev/null; then
    MSG="http://${NODE_IP}:9100/metrics serves node metrics without authentication"
    return 1
  fi
  MSG="http://${NODE_IP}:9100/metrics does not serve metrics without authentication"
}

# =====================================================================================
section "1. Cluster"
check 1.1 "node Ready, Kubernetes $KUBERNETES_VERSION" c_node
check 1.2 "all pods Ready (Completed excluded)" c_pods
check 1.3 "Helm releases deployed" c_helm

section "2. Gateway API"
check 2.1 "GatewayClass traefik Accepted" c_gatewayclass
check 2.2 "Gateway gateway/web Programmed, address = node IP" c_gateway
check 2.3 "HTTPRoutes Accepted and ResolvedRefs" c_routes

section "3. HTTP and TLS"
check 3.1 "http:// redirects to https:// (301)" c_redirect
check 3.2 "https://APP_HOST/ -> 200 \"Hello World!\", certificate verified (no -k)" c_app

section "4. Routing"
check 4.1 "header X-Version: v2 -> v2" c_route_header
check 4.2 "query ?version=v2 -> v2" c_route_query
check 4.3 "path /preview -> v2" c_route_path
check 4.4 "weighted split v1/v2 matches the HTTPRoute weights (±${SPLIT_TOLERANCE} p.p.)" c_split

section "5. Rate limit"
check 5.1 "burst gets 429, service recovers after a pause" c_ratelimit

section "6. Errors"
check 6.1 "unknown path -> 404" c_404

section "7. Metrics"
check 7.1 "Prometheus targets up" c_targets
check 7.2 "key scrape jobs present and up" c_jobs
check 7.3 "traefik_service_requests_total grows with traffic" c_traefik_counter

section "8. Logs"
check 8.1 "request with X-Request-ID reaches Loki: gateway access log" c_log_gateway
check 8.2 "request with X-Request-ID reaches Loki: application access log" c_log_app

section "9. Security"
check 9.1 "Prometheus/Loki/Alertmanager not exposed" c_no_internal_routes
check 9.2 "Grafana requires login" c_grafana_auth
check 9.3 "Pod Security Admission labels on namespaces" c_psa
check 9.4 "NetworkPolicy in ns web" c_netpol
check 9.5 "etcd metrics port 2381 closed on the node IP" c_etcd_port
check 9.6 "node-exporter port 9100 not open without authentication" c_node_exporter_port

printf '\n%s%d passed, %d failed%s' "$C_B" "$PASSED" "$FAILED" "$C_0"
((SKIPPED > 0)) && printf ', %d skipped' "$SKIPPED"
printf '\n'
((FAILED == 0))
