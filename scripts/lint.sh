#!/usr/bin/env bash
# Static checks of the repository; the same checks run in .github/workflows/lint.yml.
#
#   scripts/lint.sh               run every check
#   scripts/lint.sh shell helm    run only the named checks
#
# Checks: versions shell yaml json actions helm manifests
#   versions   versions.env is plain KEY=value, has no duplicates and sources cleanly
#   shell      shellcheck for every *.sh
#   yaml       yamllint with .yamllint (Helm templates are excluded)
#   json       Grafana dashboards are valid JSON
#   actions    actionlint for .github/workflows
#   helm       helm lint + helm template | kubeconform for every local chart in charts/
#   manifests  kubeconform for plain manifests in manifests/
#
# A missing tool is skipped with a warning; LINT_STRICT=1 (set in CI) turns that into a failure.
# Local charts are rendered with the host values deploy.sh passes (placeholder node 192.0.2.10, see LINT_SET);
# a chart that needs other values to render ships them in charts/<name>/ci/*.yaml (then LINT_SET is not used).
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"
cd "$REPO_ROOT"

ALL_CHECKS=(versions shell yaml json actions helm manifests)
# CRD schemas for kubeconform (Gateway API, monitoring.coreos.com, cert-manager, traefik.io), pinned to a commit.
CRD_CATALOG_REF="${CRD_CATALOG_REF:-7d9a4a6d97320a2ec31fcde73da298cc72d1f9be}"
CRD_SCHEMA_LOCATION="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRD_CATALOG_REF}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

# Values deploy.sh passes to local charts with --set; keys a chart does not use are ignored by Helm.
LINT_NODE_IP=192.0.2.10
LINT_SET=(
  --set-string "nodeIP=${LINT_NODE_IP}"
  --set-string "hostSuffix=${LINT_NODE_IP}.sslip.io"
  --set-string "appHost=app.${LINT_NODE_IP}.sslip.io"
  --set-string "grafanaHost=grafana.${LINT_NODE_IP}.sslip.io"
)

FAILED=()
SKIPPED=()

fail() { printf '    %sFAIL%s     %s\n' "$C_R" "$C_0" "$*" >&2; FAILED+=("$*"); }
pass() { printf '    %spass%s     %s\n' "$C_G" "$C_0" "$*"; }

# need TOOL — true if the tool is present; otherwise warns (or fails with LINT_STRICT=1).
need() {
  have "$1" && return 0
  if [[ "${LINT_STRICT:-0}" == 1 ]]; then
    fail "$1 is not installed"
  else
    warn "$1 is not installed, skipping its checks"
    SKIPPED+=("$1")
  fi
  return 1
}

# Lists repository files matching a find expression, without .git, out/ and vendored chart dependencies.
repo_files() {
  find . \( -path ./.git -o -path ./out -o -path './charts/*/charts' \) -prune -o -type f \( "$@" \) -print | sort
}

kube_version() {
  local v
  v="$(sed -n 's/^KUBERNETES_VERSION=//p' versions.env | tail -n1)"
  printf '%s' "${v#v}"
}

kubeconform_run() {
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/kubeconform"
  mkdir -p "$cache"
  kubeconform -strict -summary -cache "$cache" \
    -kubernetes-version "$(kube_version)" \
    -schema-location default \
    -schema-location "$CRD_SCHEMA_LOCATION" \
    "$@"
}

check_versions() {
  step "versions.env"
  local f=versions.env bad dups
  [[ -f "$f" ]] || { fail "$f not found"; return; }
  bad="$(grep -nvE '^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*=[^[:space:]"'"'"'`$;&|<>()\\]*$' "$f" || true)"
  if [[ -n "$bad" ]]; then
    fail "$f: lines that are not plain KEY=value:"
    printf '        %s\n' "$bad" >&2
  fi
  dups="$(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$f" | sort | uniq -d)"
  if [[ -n "$dups" ]]; then
    fail "$f: duplicate keys: $(echo "$dups" | tr '\n' ' ')"
  fi
  local sourced=1
  # shellcheck disable=SC2016  # expanded by the inner shell
  if ! env -i PATH="$PATH" bash --norc --noprofile -euc 'set -a; source ./versions.env; [[ -n "$KUBERNETES_VERSION" && -n "$HELM_VERSION" ]]' </dev/null 2>&1; then
    fail "$f does not source cleanly or misses KUBERNETES_VERSION/HELM_VERSION"
    sourced=0
  fi
  if [[ -z "$bad" && -z "$dups" && $sourced == 1 ]]; then
    pass "$f ($(grep -cE '^[A-Z]' "$f") keys)"
  fi
}

check_shell() {
  step "shellcheck"
  need shellcheck || return 0
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(repo_files -name '*.sh')
  if ((${#files[@]} == 0)); then info "no shell scripts"; return 0; fi
  if shellcheck "${files[@]}"; then pass "${#files[@]} scripts"; else fail "shellcheck"; fi
}

check_yaml() {
  step "yamllint"
  need yamllint || return 0
  if yamllint -c .yamllint .; then pass "yamllint"; else fail "yamllint"; fi
}

check_json() {
  step "dashboards (JSON)"
  need jq || return 0
  local f n=0 bad=0
  while IFS= read -r f; do
    if jq empty "$f" 2>/dev/null; then n=$((n + 1)); else fail "invalid JSON: $f"; bad=1; fi
  done < <(repo_files -name '*.json')
  if ((bad == 0)); then pass "$n JSON files"; fi
}

check_actions() {
  step "actionlint"
  need actionlint || return 0
  if actionlint; then pass "workflows"; else fail "actionlint"; fi
}

# Release name and namespace of each local chart, as deploy.sh installs it.
chart_namespace() {
  case "$1" in
    platform) echo gateway ;;
    web) echo web ;;
    observability) echo monitoring ;;
    *) echo default ;;
  esac
}

check_helm() {
  step "helm lint / helm template | kubeconform"
  need helm || return 0
  local have_kc=0 dir name ns values=() v found=0
  need kubeconform && have_kc=1
  for dir in charts/*/; do
    dir="${dir%/}"
    name="$(basename "$dir")"
    if [[ ! -f "$dir/Chart.yaml" ]]; then
      info "$dir: no Chart.yaml yet, skipped"
      continue
    fi
    found=1
    ns="$(chart_namespace "$name")"
    values=()
    for v in "$dir"/ci/*.yaml; do
      if [[ -f "$v" ]]; then values+=(-f "$v"); fi
    done
    if ((${#values[@]} == 0)); then
      values=("${LINT_SET[@]}")
      # chart-specific keys
      case "$name" in
        web) values+=(--set-string "host=app.${LINT_NODE_IP}.sslip.io") ;;
      esac
    fi
    if grep -qE '^dependencies:' "$dir/Chart.yaml" && ! helm dependency build "$dir" >/dev/null; then
      fail "$dir: helm dependency build"
      continue
    fi
    if helm lint "$dir" --namespace "$ns" "${values[@]}"; then pass "helm lint $dir"; else fail "helm lint $dir"; fi
    ((have_kc)) || continue
    # Render to a file first: a template error must not be reported as a kubeconform error.
    local rendered
    rendered="$(mktemp)"
    if ! helm template "$name" "$dir" --namespace "$ns" "${values[@]}" >"$rendered"; then
      fail "helm template $dir"
    elif kubeconform_run <"$rendered"; then  # stdin: kubeconform ignores files without a .yaml extension
      pass "kubeconform $dir"
    else
      fail "kubeconform $dir"
    fi
    rm -f "$rendered"
  done
  if ((found == 0)); then info "no local charts yet"; fi
}

check_manifests() {
  step "kubeconform manifests/"
  need kubeconform || return 0
  local files=() f
  if [[ -d manifests ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find manifests -type f \( -name '*.yaml' -o -name '*.yml' \) ! -name 'kustomization.yaml' | sort)
  fi
  if ((${#files[@]} == 0)); then info "no manifests"; return 0; fi
  if kubeconform_run "${files[@]}"; then pass "${#files[@]} manifests"; else fail "kubeconform manifests/"; fi
}

if (($# > 0)); then checks=("$@"); else checks=("${ALL_CHECKS[@]}"); fi
for c in "${checks[@]}"; do
  case " ${ALL_CHECKS[*]} " in
    *" $c "*) "check_$c" ;;
    *) die "unknown check '$c' (available: ${ALL_CHECKS[*]})" ;;
  esac
done

echo
if ((${#SKIPPED[@]})); then
  warn "skipped (tool missing): ${SKIPPED[*]}"
fi
if ((${#FAILED[@]})); then
  printf '%sLint failed:%s\n' "$C_R" "$C_0" >&2
  printf '  - %s\n' "${FAILED[@]}" >&2
  exit 1
fi
printf '%sLint passed:%s %s\n' "$C_G" "$C_0" "${checks[*]}"
