# shellcheck shell=bash
# Shared helpers for the deploy stages. Source this file; do not execute it.
#
# Conventions for every stage script:
#   * re-runnable: check state first, change only what differs, report it with `ok` or `changed`;
#   * never prompt; fail with `die` and a message that says what to do next;
#   * cluster access through `kc` (kubectl) and `helm_release`; files through `write_file`.

[[ -n "${KGS_LIB_LOADED:-}" ]] && return 0
KGS_LIB_LOADED=1

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-/var/lib/kube-gateway-stand}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
FIELD_MANAGER="kube-gateway-stand"

# ---------- output ----------
if [[ -t 1 ]]; then
  C_B=$'\e[1m' C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_C=$'\e[36m' C_0=$'\e[0m'
else
  C_B='' C_G='' C_Y='' C_R='' C_C='' C_0=''
fi
COUNT_OK=${COUNT_OK:-0}
COUNT_CHANGED=${COUNT_CHANGED:-0}

step()    { printf '%s==>%s %s%s%s\n' "$C_C" "$C_0" "$C_B" "$*" "$C_0"; }
info()    { printf '    %s\n' "$*"; }
ok()      { COUNT_OK=$((COUNT_OK + 1)); printf '    %sok%s       %s\n' "$C_G" "$C_0" "$*"; }
changed() { COUNT_CHANGED=$((COUNT_CHANGED + 1)); printf '    %schanged%s  %s\n' "$C_Y" "$C_0" "$*"; }
warn()    { printf '    %swarning%s  %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()     { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

summary() {
  printf '\n%sDone:%s ok=%d changed=%d\n' "$C_B" "$C_0" "$COUNT_OK" "$COUNT_CHANGED"
}

on_error() {
  local line=$1 cmd=$2
  printf '\n%sERROR:%s command failed (line %s): %s\n' "$C_R" "$C_0" "$line" "$cmd" >&2
  printf 'The deployment is safe to re-run: ./deploy.sh continues from the current state.\n' >&2
}

# ---------- generic helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "run as root: sudo $0"
}

# retry ATTEMPTS DELAY_SECONDS CMD...
retry() {
  local attempts=$1 delay=$2 n=1
  shift 2
  until "$@"; do
    ((n >= attempts)) && return 1
    sleep "$delay"
    n=$((n + 1))
  done
}

# wait_for TIMEOUT_SECONDS DESCRIPTION CMD...  — polls every 3 s.
wait_for() {
  local timeout=$1 desc=$2 start=$SECONDS
  shift 2
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS - start >= timeout)); then
      die "timed out after ${timeout}s waiting for: $desc"
    fi
    sleep 3
  done
}

# The non-root user who invoked sudo (for files in the repo and ~/.kube). Empty USER (cron, CI) is fine.
invoking_user() {
  local u="${SUDO_USER:-}"
  [[ -z "$u" || "$u" == root ]] && u="$(stat -c %U "$REPO_ROOT" 2>/dev/null || echo root)"
  printf '%s' "$u"
}

# write_file DEST MODE  < content
# Replaces DEST only when the content differs. Sets WRITE_CHANGED=1 if it wrote the file.
# Feed it with a heredoc or `< <(cmd)`, not `cmd | write_file`: a pipeline runs it in a subshell
# and the counters and WRITE_CHANGED are lost.
write_file() {
  local dest=$1 mode=${2:-0644} tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  WRITE_CHANGED=0  # read by callers to decide on restarts
  export WRITE_CHANGED
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    chmod "$mode" "$dest"
    ok "$dest"
  else
    install -D -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
    WRITE_CHANGED=1
    export WRITE_CHANGED
    changed "$dest"
  fi
}

# render_template SRC  — substitutes ${VARS} from the environment (only the listed ones, if given).
render_template() {
  local src=$1 vars=${2:-}
  if [[ -n "$vars" ]]; then envsubst "$vars" <"$src"; else envsubst <"$src"; fi
}

# apt_install PKG...  — installs only missing packages.
apt_install() {
  local missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -Eq '^(install|hold) ok installed$' || missing+=("$p")
  done
  if ((${#missing[@]} == 0)); then
    ok "packages present: $*"
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "${missing[@]}" >/dev/null
  changed "installed: ${missing[*]}"
}

# ---------- cluster helpers ----------
kc() { kubectl --kubeconfig "${KUBECONFIG:-/etc/kubernetes/admin.conf}" "$@"; }

# kapply FILE|DIR|- [LABEL]  — server-side apply; reports changed only when the live objects differ.
# LABEL names the objects in the output (default: the file name; give it for stdin).
kapply() {
  local src=$1 tmp rc label
  label="${2:-$(basename "$1")}"
  if [[ "$src" == "-" ]]; then
    tmp="$(mktemp)"; cat >"$tmp"; src="$tmp"
  fi
  rc=0
  kc diff --server-side --field-manager="$FIELD_MANAGER" --force-conflicts -f "$src" >/dev/null 2>&1 || rc=$?
  if ((rc == 0)); then
    ok "applied (no changes): $label"
  elif ((rc == 1)); then
    kc apply --server-side --field-manager="$FIELD_MANAGER" --force-conflicts -f "$src" >/dev/null
    changed "applied: $label"
  else
    # diff itself failed (e.g. CRD not yet known): apply and let apply report the real error.
    kc apply --server-side --field-manager="$FIELD_MANAGER" --force-conflicts -f "$src" >/dev/null
    changed "applied: $label"
  fi
  [[ -n "${tmp:-}" ]] && rm -f "$tmp"
  return 0
}

kgs_helm() { helm --kubeconfig "${KUBECONFIG:-/etc/kubernetes/admin.conf}" "$@"; }

# helm_objects_present NAME NAMESPACE — true when every object in the release manifest exists
# (someone may have deleted a Deployment, a Service or an HTTPRoute by hand).
helm_objects_present() {
  local name=$1 ns=$2 tmp rc=0
  tmp="$(mktemp -d)"
  if ! kgs_helm get manifest "$name" -n "$ns" >"$tmp/manifest" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi
  # kubectl -n would refuse objects that name another namespace (charts put some into kube-system),
  # so the release namespace goes into the context of a temporary kubeconfig instead: objects without
  # metadata.namespace are looked up there, the others in the namespace they name.
  if grep -q '^kind:' "$tmp/manifest"; then
    if kc config view --raw >"$tmp/kubeconfig" 2>/dev/null &&
      kubectl --kubeconfig "$tmp/kubeconfig" config set-context --current --namespace="$ns" >/dev/null 2>&1; then
      kubectl --kubeconfig "$tmp/kubeconfig" get -f "$tmp/manifest" -o name >/dev/null 2>&1 || rc=1
    else
      rc=1
    fi
  fi
  rm -rf "$tmp"
  return "$rc"
}

# helm_unstick NAME NAMESPACE STATUS — a release left in pending-* by an interrupted helm (lost SSH
# session, Ctrl-C, OOM) blocks every later upgrade with "another operation is in progress".
# Roll it back to its last good revision, or uninstall it if it never had one.
helm_unstick() {
  local name=$1 ns=$2 status=$3 good
  good="$(kgs_helm history "$name" -n "$ns" -o json 2>/dev/null |
    jq -r '[.[] | select(.status == "deployed" or .status == "superseded")] | last | .revision // empty' || true)"
  if [[ "$status" != pending-install && -n "$good" ]]; then
    warn "helm release $ns/$name was left in '$status' by an interrupted run: rolling back to revision $good"
    kgs_helm rollback "$name" "$good" -n "$ns" --wait --timeout "${HELM_TIMEOUT:-10m}" >/dev/null 2>&1 ||
      die "cannot roll back the interrupted release $ns/$name (helm history $name -n $ns); fix it, then re-run ./deploy.sh"
  else
    warn "helm release $ns/$name was left in '$status' by an interrupted run: uninstalling it to install again"
    kgs_helm uninstall "$name" -n "$ns" --wait --timeout "${HELM_TIMEOUT:-10m}" >/dev/null 2>&1 ||
      die "cannot uninstall the interrupted release $ns/$name (helm history $name -n $ns); fix it, then re-run ./deploy.sh"
  fi
  changed "helm release $ns/$name: interrupted operation cleaned up"
}

# helm_release NAME NAMESPACE CHART VERSION [extra helm args...]
# Skips the upgrade when chart, version, values files and --set arguments are unchanged, the
# release is deployed and all its objects exist, so a repeated run does not create new revisions.
# KGS_HELM_FORCE=1 upgrades anyway (a stage detected drift of the live objects).
helm_release() {
  local name=$1 ns=$2 chart=$3 version=$4
  shift 4
  local args=("$@") fp a i status stamp
  mkdir -p "$STATE_DIR/helm"
  stamp="$STATE_DIR/helm/${ns}_${name}.sha256"
  fp="$(
    {
      printf '%s\n' "$chart" "$version" "${args[@]}"
      for ((i = 0; i < ${#args[@]}; i++)); do
        a=${args[$i]}
        if [[ "$a" == "-f" || "$a" == "--values" ]]; then cat "${args[$((i + 1))]}"; fi
      done
      # local charts: hash their sources too
      if [[ -d "$chart" ]]; then find -L "$chart" -type f -print0 | sort -z | xargs -0 cat; fi
    } | sha256sum | cut -d' ' -f1
  )"
  status="$(kgs_helm status "$name" -n "$ns" -o json 2>/dev/null | jq -r '.info.status // empty' || true)"
  if [[ "${KGS_HELM_FORCE:-}" != 1 && "$status" == "deployed" && -f "$stamp" && "$(cat "$stamp")" == "$fp" ]]; then
    if helm_objects_present "$name" "$ns"; then
      ok "helm release $ns/$name unchanged"
      return 0
    fi
    info "helm release $ns/$name: some of its objects are missing in the cluster, upgrading to restore them"
  fi
  case "$status" in
    pending-*) helm_unstick "$name" "$ns" "$status" ;;
  esac
  local vflag=() errlog
  [[ -n "$version" && ! -d "$chart" ]] && vflag=(--version "$version")
  errlog="$(mktemp)"
  # Explicit failure handling: callers may run this where `set -e` is suspended.
  if ! kgs_helm upgrade --install "$name" "$chart" \
    -n "$ns" --create-namespace "${vflag[@]}" --wait --timeout "${HELM_TIMEOUT:-10m}" "${args[@]}" >/dev/null 2>"$errlog"; then
    cat "$errlog" >&2
    rm -f "$errlog" "$stamp"
    die "helm release $ns/$name failed; inspect: kubectl -n $ns get pods,events; then re-run ./deploy.sh"
  fi
  helm_stderr "$ns/$name" <"$errlog"
  rm -f "$errlog"
  printf '%s' "$fp" >"$stamp"
  changed "helm release $ns/$name (${version:-local})"
}

# helm_stderr RELEASE < stderr of a successful helm run
# Pod Security warnings (namespaces that enforce "privileged" keep warn=restricted on purpose) are
# shown as one readable line; informational client-go/Helm log lines (klog "I...", level=INFO, such
# as a watch that the API server closed and the client re-opened) are dropped; anything else is shown.
helm_stderr() {
  local release=$1 line
  while IFS= read -r line; do
    if [[ "$line" == *'would violate PodSecurity'* ]]; then
      line="${line#*would violate PodSecurity }"
      line="${line//\\\"/\"}"
      warn "$release: allowed, but outside Pod Security ${line%\"}"
    elif [[ "$line" =~ ^I[0-9]{4}\  || "$line" == *'level=INFO'* || -z "$line" ]]; then
      continue
    else
      printf '%s\n' "$line" >&2
    fi
  done
}

# ---------- configuration ----------
detect_node_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

load_config() {
  set -a
  # shellcheck source=/dev/null
  source "$REPO_ROOT/versions.env"
  set +a
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  NODE_IP="${NODE_IP:-$(detect_node_ip)}"
  POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
  SVC_CIDR="${SVC_CIDR:-10.96.0.0/16}"
  HOST_SUFFIX="${HOST_SUFFIX:-${NODE_IP}.sslip.io}"
  APP_HOST="${APP_HOST:-app.${HOST_SUFFIX}}"
  GRAFANA_HOST="${GRAFANA_HOST:-grafana.${HOST_SUFFIX}}"
  # PROFILE: default | small. Not given: chosen from RAM (MemTotal < 7 GiB -> small); 00-preflight says which.
  if [[ -n "${PROFILE:-}" ]]; then
    PROFILE_SOURCE=explicit
  else
    PROFILE_SOURCE=auto
    PROFILE=default
    local mem_kb
    mem_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || true)"
    [[ "$mem_kb" =~ ^[0-9]+$ ]] && ((mem_kb < 7340032)) && PROFILE=small
  fi
  [[ "$PROFILE" == default || "$PROFILE" == small ]] || die "PROFILE must be 'default' or 'small' (got '$PROFILE')"
  DOCKERHUB_MIRROR="${DOCKERHUB_MIRROR-https://mirror.gcr.io}"  # set to "" to pull from docker.io directly
  CONTAINERD_SOURCE="${CONTAINERD_SOURCE:-ubuntu}"   # ubuntu | docker
  KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
  export ARCH NODE_IP POD_CIDR SVC_CIDR HOST_SUFFIX APP_HOST GRAFANA_HOST PROFILE PROFILE_SOURCE DOCKERHUB_MIRROR CONTAINERD_SOURCE KUBECONFIG
}

# Lets a stage script run on its own (sudo ./scripts/30-platform.sh) as well as from deploy.sh.
stage_standalone_init() {
  if [[ -z "${KGS_DEPLOY:-}" ]]; then
    set -Eeuo pipefail
    trap 'on_error $LINENO "$BASH_COMMAND"' ERR
    require_root
    load_config
    trap summary EXIT
  fi
}
