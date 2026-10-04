#!/usr/bin/env bash
# Stage 00-preflight — OS, resources, ports, networks, registry access
# Owner: track A. Sourced by deploy.sh; can also run alone: sudo ./scripts/00-preflight.sh
# Changes nothing on the host except the decisions it exports (NODE_IP, CONTAINERD_SOURCE).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_standalone_init

ADMIN_CONF=/etc/kubernetes/admin.conf

# ---------- helpers (also defined in 20-cluster.sh, which can run on its own) ----------

# True if VAR was given by the user (present in the environment this shell started with).
env_explicit() { grep -qz "^$1=" "/proc/$$/environ" 2>/dev/null; }

kgs_kubectl() { kubectl --kubeconfig "$ADMIN_CONF" --request-timeout=5s "$@"; }

# Ready = API /readyz answers "ok" + ConfigMap kubeadm-config + Deployment CoreDNS exist.
# admin.conf alone is not enough: kubeadm writes it before etcd and the control plane are up.
cluster_ready() {
  [[ -f "$ADMIN_CONF" ]] && have kubectl || return 1
  [[ "$(kgs_kubectl get --raw=/readyz 2>/dev/null)" == ok ]] || return 1
  kgs_kubectl -n kube-system get configmap kubeadm-config >/dev/null 2>&1 || return 1
  kgs_kubectl -n kube-system get deployment coredns >/dev/null 2>&1
}

cluster_traces() {
  local f
  for f in "$ADMIN_CONF" /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/etcd.yaml \
    /var/lib/etcd/member /var/lib/kubelet/config.yaml; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

# Prints none | ready | broken. After a reboot the API needs a minute: wait up to 180 s for it.
cluster_state() {
  if ! cluster_traces; then echo none; return 0; fi
  local start=$SECONDS
  cluster_ready || printf '    waiting up to 180 s for the existing cluster API (e.g. right after a reboot)\n' >&2
  until cluster_ready; do
    if ((SECONDS - start >= 180)) || ! systemctl is-enabled --quiet kubelet 2>/dev/null; then
      echo broken
      return 0
    fi
    sleep 5
  done
  echo ready
}

# Address of the API server recorded in admin.conf (host part only).
cluster_address() {
  awk '$1 == "server:" { print $2; exit }' "$ADMIN_CONF" 2>/dev/null | sed -E 's#^https?://##; s#:[0-9]+/?$##; s#^\[##; s#\]$##'
}

# ---------- IPv4 CIDR arithmetic ----------
is_ipv4() {
  local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
  [[ $1 =~ $re ]] || return 1
  ((BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 && BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255))
}
is_cidr() { [[ $1 == */* ]] && is_ipv4 "${1%/*}" && [[ ${1#*/} =~ ^[0-9]+$ ]] && ((${1#*/} <= 32)); }
ip2int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}
# cidr_range CIDR|IP -> "first last" as integers
cidr_range() {
  local ip=${1%/*} len=32 n mask
  [[ $1 == */* ]] && len=${1#*/}
  n=$(ip2int "$ip")
  mask=$(((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF))
  ((len == 0)) && mask=0
  echo "$((n & mask)) $(((n & mask) | (~mask & 0xFFFFFFFF)))"
}
cidr_overlap() {
  local s1 e1 s2 e2
  read -r s1 e1 <<<"$(cidr_range "$1")"
  read -r s2 e2 <<<"$(cidr_range "$2")"
  ((s1 <= e2 && s2 <= e1))
}

# Networks the node already uses: interface addresses and routes. Calico's own interfaces and
# blackhole routes are skipped, so a re-run on our cluster does not report itself.
node_networks() {
  ip -4 -o addr show | awk '$2 !~ /^(cali|vxlan\.calico|tunl0)/ { print $4 " (address on " $2 ")" }'
  ip -4 route show | awk '
    $1 == "default" || $1 == "blackhole" || $1 == "unreachable" || $1 == "prohibit" { next }
    { dev = ""; for (i = 1; i < NF; i++) if ($i == "dev") dev = $(i + 1) }
    dev ~ /^(cali|vxlan\.calico|tunl0)/ { next }
    { print $1 " (route via " (dev == "" ? "?" : dev) ")" }'
}

# "install ok installed" or "hold ok installed"
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Eq '^(install|hold) ok installed$'; }

# ---------- 1. operating system ----------
step "preflight: operating system"
# shellcheck source=/dev/null
os_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
# shellcheck source=/dev/null
os_ver="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
if [[ "$os_id" != ubuntu || "$os_ver" != 24.04 ]]; then
  die "this deployment supports Ubuntu 24.04 only (found: ${os_id:-unknown} ${os_ver:-unknown}). Package names, the containerd version and the cgroup v2 layout are checked against Ubuntu 24.04."
fi
ok "Ubuntu $os_ver"
case "$ARCH" in
  amd64 | arm64) ok "architecture $ARCH" ;;
  *) die "unsupported architecture '$ARCH': only amd64 and arm64 are supported" ;;
esac
[[ "$(ps -p 1 -o comm= 2>/dev/null)" == systemd ]] || die "systemd is not PID 1 (containers/WSL without systemd are not supported): kubelet and containerd run as systemd services"
ok "systemd is PID 1"
cgfs="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)"
[[ "$cgfs" == cgroup2fs ]] || die "cgroup v2 is required (found '$cgfs' on /sys/fs/cgroup): Kubernetes 1.35+ refuses to run on cgroup v1. Boot with systemd.unified_cgroup_hierarchy=1."
ok "cgroup v2"

if have cloud-init && ! cloud-init status 2>/dev/null | grep -q 'status: done'; then
  info "waiting for cloud-init to finish (up to 300 s)"
  timeout 300 cloud-init status --wait >/dev/null 2>&1 || warn "cloud-init did not report 'done' within 300 s; continuing (apt may be busy)"
fi

if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]; then
  ok "system clock synchronized"
else
  warn "system clock is not NTP-synchronized; certificates and etcd need a correct clock (timedatectl set-ntp true)"
fi

# ---------- 2. existing cluster ----------
step "preflight: existing cluster"
CLUSTER_STATE="$(cluster_state)"
export CLUSTER_STATE
case "$CLUSTER_STATE" in
  none) ok "no Kubernetes cluster on this host yet" ;;
  broken)
    die "found traces of a previous 'kubeadm init' (/etc/kubernetes, /var/lib/etcd or /var/lib/kubelet), but the cluster is not ready (/readyz, ConfigMap kubeadm-config, Deployment coredns). Nothing was changed. Remove it with 'make destroy' (or: sudo YES=1 ./scripts/destroy.sh) and run the deployment again."
    ;;
  ready)
    addr="$(cluster_address)"
    if [[ -n "$addr" && "$addr" != "$NODE_IP" ]]; then
      if ! env_explicit NODE_IP && ip -4 -o addr show | awk '{ sub(/\/.*/, "", $4); print $4 }' | grep -qxF "$addr"; then
        # NODE_IP was auto-detected (e.g. the default route moved to another interface): keep the cluster address.
        info "using the address the cluster was created with: $addr (auto-detected $NODE_IP)"
        [[ "$HOST_SUFFIX" == "${NODE_IP}.sslip.io" ]] && HOST_SUFFIX="${addr}.sslip.io"
        [[ "$APP_HOST" == "app.${NODE_IP}.sslip.io" ]] && APP_HOST="app.${HOST_SUFFIX}"
        [[ "$GRAFANA_HOST" == "grafana.${NODE_IP}.sslip.io" ]] && GRAFANA_HOST="grafana.${HOST_SUFFIX}"
        NODE_IP="$addr"
        export NODE_IP HOST_SUFFIX APP_HOST GRAFANA_HOST
      elif env_explicit NODE_IP; then
        die "the cluster was created with address $addr, but NODE_IP=$NODE_IP was given. Unset NODE_IP or run 'make destroy' first. Nothing was changed."
      else
        die "the cluster was created with address $addr, which is no longer on any interface of this host (the node IP changed, e.g. DHCP after a reboot). Restore the address or run 'make destroy' and deploy again. Nothing was changed."
      fi
    fi
    ok "cluster is ready at $NODE_IP (re-run: existing cluster will be reused)"
    ;;
esac

# ---------- 3. resources ----------
step "preflight: resources"
cpus="$(nproc)"
((cpus >= 2)) || die "at least 2 CPUs are required (found $cpus)"
ok "CPUs: $cpus"
mem_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
mem_gib="$(awk -v k="$mem_kb" 'BEGIN { printf "%.1f", k / 1048576 }')"
((mem_kb >= 3670016)) || die "at least 3.5 GiB of RAM is required (found ${mem_gib} GiB)"
if [[ "$PROFILE_SOURCE" == auto && "$PROFILE" == small ]]; then
  ok "RAM: ${mem_gib} GiB (< 7 GiB): PROFILE=small selected automatically (lower requests/limits and retention; override: sudo PROFILE=default ./deploy.sh)"
elif ((mem_kb < 7340032)) && [[ "$PROFILE" != small ]]; then
  warn "RAM is ${mem_gib} GiB (< 7 GiB), but PROFILE=$PROFILE was given: requests and retention are sized for 8 GB, little memory stays free; PROFILE=small is meant for 2 vCPU / 4 GB"
else
  ok "RAM: ${mem_gib} GiB (profile: $PROFILE, ${PROFILE_SOURCE:-explicit})"
fi
var_free_kb="$(df -Pk /var | awk 'NR == 2 { print $4 }')"
var_free_gib=$((var_free_kb / 1048576))
if ((var_free_kb >= 20971520)); then
  ok "free disk on /var: ${var_free_gib} GiB"
elif [[ "$CLUSTER_STATE" == ready ]]; then
  warn "free disk on /var: ${var_free_gib} GiB (< 20 GiB); images and metrics may fill it up"
else
  die "at least 20 GiB free on /var is required for images, etcd and metrics (found ${var_free_gib} GiB)"
fi

# ---------- 4. network ----------
step "preflight: network"
[[ -n "$NODE_IP" ]] || die "cannot detect the node address (no default route?). Set it explicitly: sudo NODE_IP=<address> ./deploy.sh"
is_ipv4 "$NODE_IP" || die "NODE_IP='$NODE_IP' is not an IPv4 address"
ip -4 -o addr show | awk '{ sub(/\/.*/, "", $4); print $4 }' | grep -qxF "$NODE_IP" ||
  die "NODE_IP=$NODE_IP is not assigned to any interface of this host (see 'ip -4 addr'). Set NODE_IP to a local address."
ok "NODE_IP $NODE_IP is a local address"

is_cidr "$POD_CIDR" || die "POD_CIDR='$POD_CIDR' is not an IPv4 CIDR"
is_cidr "$SVC_CIDR" || die "SVC_CIDR='$SVC_CIDR' is not an IPv4 CIDR"
cidr_overlap "$POD_CIDR" "$SVC_CIDR" && die "POD_CIDR $POD_CIDR and SVC_CIDR $SVC_CIDR overlap; choose separate ranges"
while read -r net rest; do
  [[ -n "$net" ]] || continue
  is_cidr "$net" || is_ipv4 "$net" || continue
  for pair in "POD_CIDR:$POD_CIDR" "SVC_CIDR:$SVC_CIDR"; do
    if cidr_overlap "${pair#*:}" "$net"; then
      die "${pair%%:*} ${pair#*:} overlaps with $net $rest on this host. Pick free ranges, e.g. sudo POD_CIDR=10.244.0.0/16 SVC_CIDR=10.96.0.0/16 ./deploy.sh (with other values)."
    fi
  done
done < <(node_networks)
ok "POD_CIDR $POD_CIDR and SVC_CIDR $SVC_CIDR do not overlap with host networks"

if [[ "$CLUSTER_STATE" == none ]]; then
  listening="$(ss -Hltnp 2>/dev/null || true)"
  busy=()
  for port in 6443 2379 2380 10250 10257 10259 80 443; do
    line="$(awk -v p=":$port" '{ n = length($4) - length(p) + 1; if (substr($4, n) == p) { print; exit } }' <<<"$listening")"
    if [[ -n "$line" ]]; then
      proc="$(grep -o 'users:(("[^"]*"' <<<"$line" | sed 's/users:(("//; s/"$//' || true)"
      busy+=("$port${proc:+ ($proc)}")
    fi
  done
  ((${#busy[@]} == 0)) || die "ports already in use: ${busy[*]}. Kubernetes (6443, 2379-2380, 10250, 10257, 10259) and the gateway (80, 443) need them; stop the services that hold them."
  ok "ports 6443 2379 2380 10250 10257 10259 80 443 are free"
else
  ok "ports are held by this cluster (re-run)"
fi

# ---------- 5. container runtime packages ----------
step "preflight: container runtime"
if pkg_installed containerd.io; then
  if ! env_explicit CONTAINERD_SOURCE; then
    CONTAINERD_SOURCE=docker
    export CONTAINERD_SOURCE
    info "Docker's containerd.io is installed: using CONTAINERD_SOURCE=docker (its config is backed up and replaced; CRI gets enabled)"
  elif [[ "$CONTAINERD_SOURCE" != docker ]]; then
    die "Docker's containerd.io is installed, but CONTAINERD_SOURCE=$CONTAINERD_SOURCE: installing Ubuntu's containerd would remove Docker's runtime. Use CONTAINERD_SOURCE=docker (or omit it)."
  fi
fi
case "$CONTAINERD_SOURCE" in
  ubuntu) ok "containerd source: Ubuntu archive (>= $CONTAINERD_MIN_VERSION)" ;;
  docker)
    if pkg_installed containerd && ! pkg_installed containerd.io; then
      die "Ubuntu's containerd package is installed, but CONTAINERD_SOURCE=docker would replace it with containerd.io. Use CONTAINERD_SOURCE=ubuntu (default)."
    fi
    ok "containerd source: Docker apt repository (containerd.io)"
    ;;
  *) die "CONTAINERD_SOURCE must be 'ubuntu' or 'docker' (got '$CONTAINERD_SOURCE')" ;;
esac

# ---------- 6. registries and repositories (warnings only) ----------
step "preflight: access to package repositories and registries"
if have curl; then
  targets=(
    "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key"
    "https://registry.k8s.io/v2/"
    "https://quay.io/v2/"
    "https://ghcr.io/v2/"
    "https://registry-1.docker.io/v2/"
    "https://github.com/projectcalico/calico/releases/download/${CALICO_VERSION}/tigera-operator-${CALICO_VERSION}.tgz"
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz.sha256sum"
  )
  [[ -n "$DOCKERHUB_MIRROR" ]] && targets+=("${DOCKERHUB_MIRROR%/}/v2/")
  [[ "$CONTAINERD_SOURCE" == docker ]] && targets+=("https://download.docker.com/linux/ubuntu/gpg")
  dockerhub_ok=0
  for url in "${targets[@]}"; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)"
    if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
      ok "reachable: ${url%/v2/} (HTTP $code)"
      [[ "$url" == *docker.io/v2/ || ("$url" == "${DOCKERHUB_MIRROR%/}/v2/" && -n "$DOCKERHUB_MIRROR") ]] && dockerhub_ok=1
    else
      warn "not reachable within 10 s: $url (image pulls or package downloads from it may fail)"
    fi
  done
  ((dockerhub_ok)) || warn "neither Docker Hub nor its mirror is reachable: docker.io images will not pull (set DOCKERHUB_MIRROR to a reachable mirror)"
else
  warn "curl is not installed yet; skipping repository checks (stage 10-node installs it)"
fi
