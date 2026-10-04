#!/usr/bin/env bash
# Change the canary split of the web app on the fly (no sudo needed):
#   ./scripts/canary.sh W      # W = share of "/" traffic for v2, 0..100 (v1 gets 100-W)
# The change lives until the next deploy; CANARY_WEIGHT=W ./deploy.sh makes it permanent.
set -Eeuo pipefail

usage() { printf 'usage: %s WEIGHT   (share of traffic for v2, 0..100)\n' "$(basename "$0")" >&2; exit 2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 ]] || usage
w=$1
if ! [[ "$w" =~ ^[0-9]+$ ]] || ((10#$w > 100)); then
  fail "weight must be an integer 0..100, got '$w'"
fi
w=$((10#$w))

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found: run 'sudo ./deploy.sh' first"
kcfg="${KUBECONFIG:-$HOME/.kube/config}"
[[ -r "$kcfg" ]] || fail "kubeconfig $kcfg is not readable: run 'sudo ./deploy.sh' (it writes ~/.kube/config) or set KUBECONFIG"
export KUBECONFIG="$kcfg"

ns=web
route=web
names="$(kubectl -n "$ns" get httproute "$route" -o jsonpath='{range .spec.rules[*]}{.name}{"\n"}{end}' 2>/dev/null)" \
  || fail "HTTPRoute $ns/$route not found: deploy the app first (sudo ./deploy.sh)"
idx="$(awk '$0 == "canary" { print NR - 1; exit }' <<<"$names")"
[[ -n "$idx" ]] || fail "HTTPRoute $ns/$route has no rule named 'canary'"

base="/spec/rules/$idx/backendRefs"
patch="$(printf '[{"op":"test","path":"%s/0/name","value":"web-v1"},{"op":"test","path":"%s/1/name","value":"web-v2"},{"op":"replace","path":"%s/0/weight","value":%d},{"op":"replace","path":"%s/1/weight","value":%d}]' \
  "$base" "$base" "$base" $((100 - w)) "$base" "$w")"
kubectl -n "$ns" patch httproute "$route" --type=json -p "$patch" >/dev/null \
  || fail "could not patch HTTPRoute $ns/$route"

printf 'Canary weights of HTTPRoute %s/%s (rule "canary"):\n' "$ns" "$route"
kubectl -n "$ns" get httproute "$route" \
  -o jsonpath="{range .spec.rules[$idx].backendRefs[*]}  {.name}: {.weight}{\"\\n\"}{end}"
host="$(kubectl -n "$ns" get httproute "$route" -o jsonpath='{.spec.hostnames[0]}')"
ca="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/out/ca.crt"
# shellcheck disable=SC2016  # the loop is printed for the user, not run
printf 'Check:  for i in $(seq 100); do curl -s --cacert %s https://%s/; done | sort | uniq -c\n' "$ca" "$host"
printf 'This lasts until the next deploy. To make it permanent: CANARY_WEIGHT=%d ./deploy.sh\n' "$w"
