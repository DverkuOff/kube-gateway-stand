#!/usr/bin/env bash
# Prints access details: application and Grafana URLs, Grafana login, CA path, port-forward hints.
# Runs as a regular user (no sudo) with ~/.kube/config written by the deployment.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA="$REPO_ROOT/out/ca.crt"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || die "kubectl not found; run sudo ./deploy.sh first"
kubectl get --raw /readyz --request-timeout=5s >/dev/null 2>&1 \
  || die "cannot reach the cluster with ${KUBECONFIG:-$HOME/.kube/config}; run sudo ./deploy.sh (it writes the kubeconfig for your user)"

node_ip="$(kubectl -n gateway get gateway web -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
app_host="$(kubectl -n web get httproute -o jsonpath='{.items[0].spec.hostnames[0]}' 2>/dev/null || true)"
grafana_host="$(kubectl -n monitoring get httproute grafana -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || true)"
grafana_user="$(kubectl -n monitoring get secret grafana-admin -o go-template='{{index .data "admin-user" | base64decode}}' 2>/dev/null || true)"
grafana_pass="$(kubectl -n monitoring get secret grafana-admin -o go-template='{{index .data "admin-password" | base64decode}}' 2>/dev/null || true)"

b=''; n=''
if [[ -t 1 ]]; then b=$'\e[1m'; n=$'\e[0m'; fi

printf '%sApplication%s\n' "$b" "$n"
printf '  URL:       https://%s/\n' "${app_host:-<not deployed yet>}"
printf '  Gateway:   %s\n' "${node_ip:-<no address in Gateway status>}"
if [[ -f "$CA" ]]; then
  printf '  CA:        %s  (import into the browser to avoid the certificate warning)\n' "$CA"
  if [[ -n "$app_host" ]]; then
    printf '  Check:     curl --cacert %s https://%s/\n' "$CA" "$app_host"
  fi
else
  printf '  CA:        %s is missing (stage 30-platform exports it)\n' "$CA"
fi

printf '\n%sGrafana%s\n' "$b" "$n"
printf '  URL:       https://%s/\n' "${grafana_host:-<not deployed yet>}"
if [[ -n "$grafana_pass" ]]; then
  printf '  Login:     %s\n' "$grafana_user"
  printf '  Password:  %s\n' "$grafana_pass"
else
  printf '  Login:     secret monitoring/grafana-admin not found (stage 50-monitoring creates it)\n'
fi
printf '  Dashboards: "Web: golden signals", "Traefik Official Kubernetes Dashboard", Kubernetes / Compute Resources / *\n'

printf '\n%sPrometheus and Loki (not published through the Gateway)%s\n' "$b" "$n"
printf '  Prometheus: kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090   -> http://localhost:9090\n'
printf '  Loki API:   kubectl -n logging port-forward svc/loki 3100:3100              -> http://localhost:3100/ready\n'
printf '  From another machine: ssh -L 9090:localhost:9090 <user>@%s, then run the port-forward on the host\n' "${node_ip:-<node>}"
