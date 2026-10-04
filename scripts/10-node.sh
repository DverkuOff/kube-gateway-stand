#!/usr/bin/env bash
# Stage 10-node — kernel settings, containerd, kubeadm/kubelet/kubectl, helm
# Sourced by deploy.sh; can also run alone: sudo ./scripts/10-node.sh
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_standalone_init

MARKER="# Managed by kube-gateway-stand (scripts/10-node.sh); re-run deploy.sh instead of editing."
K8S_REPO="https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/"
K8S_KEYRING=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
# Fingerprint of the pkgs.k8s.io signing key (isv:kubernetes OBS Project).
K8S_KEY_FPR=DE15B14486CD377B9E876E1A234654DA9A296436
DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
APT_UPDATED=0
# needrestart (Ubuntu) prints its report on every apt install; services are restarted by this stage itself.
export NEEDRESTART_SUSPEND=1

# "install ok installed" or "hold ok installed"
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Eq '^(install|hold) ok installed$'; }
pkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

# On a fresh VM apt-daily or unattended-upgrades may hold the package lists lock for minutes:
# wait for it (up to 10 min) instead of failing; other errors are retried 3 times.
apt_refresh() {
  ((APT_UPDATED)) && return 0
  info "apt-get update"
  local err fails=0 waits=0
  err="$(mktemp)"
  until apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update -qq >/dev/null 2>"$err"; do
    if grep -q 'Could not get lock' "$err" && ((waits < 60)); then
      if ((waits == 0)); then
        info "apt is busy (apt-daily or unattended-upgrades): waiting for the lock, up to 10 min"
      fi
      waits=$((waits + 1))
    elif ((++fails >= 3)); then
      cat "$err" >&2
      rm -f "$err"
      die "apt-get update failed: check access to the Ubuntu archive and $K8S_REPO"
    fi
    sleep 10
  done
  rm -f "$err"
  APT_UPDATED=1
}

apt_get_install() {
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 \
    install -y -qq --no-install-recommends "$@" >/dev/null
}

hold() {
  local p held
  held="$(apt-mark showhold)"
  for p in "$@"; do
    if grep -qxF "$p" <<<"$held"; then
      ok "apt hold: $p"
    else
      apt-mark hold "$p" >/dev/null
      changed "apt hold: $p"
    fi
  done
}

# key_fingerprints FILE -> primary key fingerprints of an armored or binary key file
key_fingerprints() {
  local gh
  gh="$(mktemp -d)"
  GNUPGHOME="$gh" gpg --batch --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1 == "pub" { want = 1 } $1 == "fpr" && want { print $10; want = 0 }'
  rm -rf "$gh"
}

# ---------- base packages ----------
step "node: base packages"
base_pkgs=(ca-certificates curl gpg jq conntrack socat ipset gettext-base make iptables)
for p in "${base_pkgs[@]}"; do
  pkg_installed "$p" || { apt_refresh; break; }
done
apt_install "${base_pkgs[@]}"

# ---------- swap ----------
step "node: swap"
if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  swapoff -a
  changed "swap turned off"
else
  ok "swap is off"
fi
swap_re='^[^#[:space:]][^[:space:]]*[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]|$)'
if grep -Eq "$swap_re" /etc/fstab; then
  cp -a /etc/fstab "/etc/fstab.bak-kgs-$(date +%Y%m%d%H%M%S)"
  sed -Ei "s@$swap_re@# disabled by kube-gateway-stand: &@" /etc/fstab
  changed "swap entries commented out in /etc/fstab (backup: /etc/fstab.bak-kgs-*)"
else
  ok "no active swap entries in /etc/fstab"
fi

# ---------- kernel modules ----------
step "node: kernel modules"
write_file /etc/modules-load.d/kube-gateway-stand.conf 0644 < <(printf '%s\n' "$MARKER" overlay br_netfilter)
for m in overlay br_netfilter; do
  if [[ -d "/sys/module/$m" ]]; then
    ok "module $m loaded"
  else
    modprobe "$m" || die "cannot load kernel module $m"
    changed "module $m loaded"
  fi
done

# ---------- sysctl ----------
# The file name starts with "zz-" so it is applied after every other file in /etc/sysctl.d,
# including 99-sysctl.conf (the /etc/sysctl.conf link): nothing installed earlier can override it.
step "node: sysctl"
SYSCTL_FILE=/etc/sysctl.d/zz-kube-gateway-stand.conf
sysctls=(
  net.ipv4.ip_forward=1
  net.bridge.bridge-nf-call-iptables=1
  net.bridge.bridge-nf-call-ip6tables=1
  fs.inotify.max_user_instances=8192
  fs.inotify.max_user_watches=524288
)
write_file "$SYSCTL_FILE" 0644 < <(printf '%s\n' "$MARKER" "${sysctls[@]}")
sysctl_file_changed=$WRITE_CHANGED
sysctl_mismatch() {
  local kv key want got
  for kv in "${sysctls[@]}"; do
    key=${kv%%=*} want=${kv#*=}
    got="$(sysctl -n "$key" 2>/dev/null || echo '?')"
    [[ "$got" == "$want" ]] || { echo "$key=$got (want $want)"; return 0; }
  done
  return 1
}
if ((sysctl_file_changed)) || sysctl_mismatch >/dev/null; then
  sysctl -q -p "$SYSCTL_FILE" >/dev/null
  changed "sysctl values applied"
fi
if bad="$(sysctl_mismatch)"; then
  die "kernel parameter $bad after applying $SYSCTL_FILE: something else overrides it (check /etc/sysctl.d, /run/sysctl.d, /etc/sysctl.conf)"
fi
ok "kernel parameters verified: ${sysctls[*]}"

# ---------- NetworkManager (Ubuntu Desktop) ----------
# On Ubuntu Desktop NetworkManager manages every interface, including the ones Calico creates, and
# may take them over or touch their routes. Calico's documentation asks to leave them unmanaged.
# Ubuntu Server (systemd-networkd) skips this.
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
  step "node: NetworkManager"
  write_file /etc/NetworkManager/conf.d/kube-gateway-stand-calico.conf 0644 < <(printf '%s\n' "$MARKER" '[keyfile]' \
    'unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico')
  if ((WRITE_CHANGED)); then
    systemctl reload NetworkManager || warn "cannot reload NetworkManager; the Calico interfaces become unmanaged after its restart"
    changed "NetworkManager: Calico interfaces unmanaged"
  fi
fi

# ---------- containerd ----------
step "node: containerd ($CONTAINERD_SOURCE)"
if [[ "$CONTAINERD_SOURCE" == docker ]]; then
  if pkg_installed containerd.io; then
    v="$(pkg_version containerd.io)"
    if [[ "$v" == "$CONTAINERD_IO_VERSION" ]]; then
      ok "containerd.io $v"
    else
      warn "containerd.io $v is already installed (Docker); keeping it instead of $CONTAINERD_IO_VERSION"
    fi
  else
    pkg_installed containerd && die "Ubuntu's containerd is installed; CONTAINERD_SOURCE=docker would replace it. Use CONTAINERD_SOURCE=ubuntu."
    if grep -rqs 'download.docker.com' /etc/apt/sources.list /etc/apt/sources.list.d/; then
      ok "Docker apt repository already configured"
    else
      tmp="$(mktemp)"
      retry 3 5 curl -fsSL --max-time 30 -o "$tmp" https://download.docker.com/linux/ubuntu/gpg ||
        die "cannot download the Docker apt key from download.docker.com"
      key_fingerprints "$tmp" | grep -qxF "$DOCKER_KEY_FPR" || die "unexpected fingerprint of the Docker apt key (want $DOCKER_KEY_FPR)"
      write_file "$DOCKER_KEYRING" 0644 <"$tmp"
      rm -f "$tmp"
      write_file /etc/apt/sources.list.d/docker.list 0644 \
        <<<"deb [arch=$ARCH signed-by=$DOCKER_KEYRING] https://download.docker.com/linux/ubuntu noble stable"
      APT_UPDATED=0
    fi
    apt_refresh
    apt_get_install "containerd.io=$CONTAINERD_IO_VERSION" ||
      die "cannot install containerd.io=$CONTAINERD_IO_VERSION from the Docker repository"
    changed "installed containerd.io $CONTAINERD_IO_VERSION"
  fi
  hold containerd.io
  v="$(pkg_version containerd.io)"
else
  v="$(pkg_version containerd)"
  if pkg_installed containerd && pkg_installed runc && dpkg --compare-versions "$v" ge "$CONTAINERD_MIN_VERSION"; then
    ok "containerd $v, runc $(pkg_version runc) (Ubuntu archive)"
  else
    apt_refresh
    cand="$(apt-cache policy containerd | awk '/Candidate:/ { print $2 }')"
    dpkg --compare-versions "${cand:-0}" ge "$CONTAINERD_MIN_VERSION" ||
      die "the Ubuntu archive offers containerd ${cand:-none}, but >= $CONTAINERD_MIN_VERSION is required (Kubernetes ${KUBERNETES_MINOR}). Enable the noble-updates pocket in /etc/apt/sources.list.d/ubuntu.sources."
    apt_get_install --allow-change-held-packages containerd runc || die "cannot install containerd and runc from the Ubuntu archive"
    v="$(pkg_version containerd)"
    changed "installed containerd $v, runc $(pkg_version runc)"
  fi
  hold containerd runc
fi
dpkg --compare-versions "$v" ge "$CONTAINERD_MIN_VERSION" || die "containerd $v is older than the required $CONTAINERD_MIN_VERSION"

# Config: `containerd config default` of the installed version + three edits, verified below.
render_containerd_config() {
  local out
  out="$(containerd config default | awk -v q="'" -v pause="$PAUSE_IMAGE" \
    -v s_pin="[plugins.'io.containerd.cri.v1.images'.pinned_images]" \
    -v s_reg="[plugins.'io.containerd.cri.v1.images'.registry]" \
    -v s_runc="[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]" '
    function indent() { match($0, /^[[:space:]]*/); return substr($0, 1, RLENGTH) }
    /^[[:space:]]*\[/ { s = $0; sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); sec = s }
    sec == s_pin  && $1 == "sandbox"       { print indent() "sandbox = " q pause q; n1++; next }
    sec == s_reg  && $1 == "config_path"   { print indent() "config_path = " q "/etc/containerd/certs.d" q; n2++; next }
    sec == s_runc && $1 == "SystemdCgroup" { print indent() "SystemdCgroup = true"; n3++; next }
    $1 == "disabled_plugins" && /cri/      { bad = 1 }
    { print }
    END { if (n1 != 1 || n2 != 1 || n3 != 1 || bad) exit 3 }')" ||
    die "unexpected output of 'containerd config default' (containerd $v): cannot set SystemdCgroup, sandbox image and config_path"
  printf '%s\n%s\n' "$MARKER" "$out"
}
cfg=/etc/containerd/config.toml
new_cfg="$(render_containerd_config)"
if [[ -f "$cfg" ]] && ! head -n1 "$cfg" | grep -qxF "$MARKER" && [[ "$(cat "$cfg")" != "$new_cfg" ]]; then
  backup="$cfg.bak-kgs-$(date +%Y%m%d%H%M%S)"
  cp -a "$cfg" "$backup"
  info "existing $cfg saved as $backup"
fi
write_file "$cfg" 0644 <<<"$new_cfg"
containerd_changed=$WRITE_CHANGED

hosts_toml=/etc/containerd/certs.d/docker.io/hosts.toml
if [[ -n "$DOCKERHUB_MIRROR" ]]; then
  write_file "$hosts_toml" 0644 <<EOF
$MARKER
# docker.io pulls try the mirror first, then Docker Hub itself.
server = "https://registry-1.docker.io"

[host."${DOCKERHUB_MIRROR%/}"]
  capabilities = ["pull", "resolve"]

[host."https://registry-1.docker.io"]
  capabilities = ["pull", "resolve"]
EOF
elif [[ -f "$hosts_toml" ]] && grep -qxF "$MARKER" "$hosts_toml"; then
  rm -f "$hosts_toml"
  changed "removed docker.io mirror config (DOCKERHUB_MIRROR is empty)"
else
  ok "no docker.io mirror configured (DOCKERHUB_MIRROR is empty)"
fi

if ! systemctl is-enabled --quiet containerd; then
  systemctl enable containerd >/dev/null 2>&1
  changed "containerd enabled"
fi
if ((containerd_changed)) || ! systemctl is-active --quiet containerd; then
  systemctl restart containerd
  changed "containerd restarted"
else
  ok "containerd running, config unchanged"
fi
wait_for 60 "containerd socket /run/containerd/containerd.sock" test -S /run/containerd/containerd.sock

write_file /etc/crictl.yaml 0644 <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 30
EOF

# ---------- Kubernetes packages ----------
step "node: kubeadm, kubelet, kubectl $KUBERNETES_PKG_VERSION"
install -d -m 0755 /etc/apt/keyrings
if [[ -s "$K8S_KEYRING" ]] && key_fingerprints "$K8S_KEYRING" | grep -qxF "$K8S_KEY_FPR"; then
  ok "$K8S_KEYRING (fingerprint verified)"
else
  tmp="$(mktemp)"
  retry 3 5 curl -fsSL --max-time 30 -o "$tmp" "${K8S_REPO}Release.key" || die "cannot download ${K8S_REPO}Release.key"
  key_fingerprints "$tmp" | grep -qxF "$K8S_KEY_FPR" ||
    die "the pkgs.k8s.io signing key has an unexpected fingerprint (want $K8S_KEY_FPR); refusing to trust it"
  write_file "$K8S_KEYRING" 0644 < <(gpg --batch --yes --dearmor <"$tmp")
  rm -f "$tmp"
fi
write_file /etc/apt/sources.list.d/kubernetes.list 0644 <<<"deb [signed-by=$K8S_KEYRING] $K8S_REPO /"
((WRITE_CHANGED)) && APT_UPDATED=0
# Kubernetes packages come only from pkgs.k8s.io, even if another repository (e.g. on CI runners)
# offers newer ones.
write_file /etc/apt/preferences.d/kubernetes 0644 <<EOF
$MARKER
Package: kubeadm kubelet kubectl cri-tools kubernetes-cni
Pin: origin pkgs.k8s.io
Pin-Priority: 1001
EOF

k8s_pkgs=(kubeadm kubelet kubectl)
need=0
for p in "${k8s_pkgs[@]}"; do
  [[ "$(pkg_version "$p")" == "$KUBERNETES_PKG_VERSION" ]] || need=1
done
# crictl (cri-tools) is no longer a dependency of kubeadm; kubeadm and the checks use it.
pkg_installed cri-tools || need=1
if ((need)); then
  apt_refresh
  apt_get_install --allow-downgrades --allow-change-held-packages \
    "kubeadm=$KUBERNETES_PKG_VERSION" "kubelet=$KUBERNETES_PKG_VERSION" "kubectl=$KUBERNETES_PKG_VERSION" cri-tools ||
    die "cannot install Kubernetes packages $KUBERNETES_PKG_VERSION from $K8S_REPO"
  changed "installed kubeadm, kubelet, kubectl $KUBERNETES_PKG_VERSION, cri-tools $(pkg_version cri-tools)"
else
  ok "kubeadm, kubelet, kubectl $KUBERNETES_PKG_VERSION, cri-tools $(pkg_version cri-tools)"
fi
hold "${k8s_pkgs[@]}" cri-tools
if systemctl is-enabled --quiet kubelet; then
  ok "kubelet enabled"
else
  systemctl enable kubelet >/dev/null 2>&1
  changed "kubelet enabled"
fi

# The runtime must report the systemd cgroup driver (kubelet 1.34+ takes it from the runtime).
sc="$(crictl info 2>/dev/null | jq -r '.config.containerd.runtimes.runc.options.SystemdCgroup // empty' || true)"
[[ "$sc" == true ]] || die "containerd does not report SystemdCgroup=true (got '${sc:-nothing}'); check $cfg"
ok "containerd CRI: SystemdCgroup=true"

# ---------- helm ----------
step "node: helm $HELM_VERSION"
helm_bin=/usr/local/bin/helm
if [[ -x "$helm_bin" && "$("$helm_bin" version --template '{{.Version}}' 2>/dev/null || true)" == "$HELM_VERSION" ]]; then
  ok "helm $HELM_VERSION"
else
  sum_var="HELM_SHA256_${ARCH^^}"
  want_sum="${!sum_var:-}"
  [[ -n "$want_sum" ]] || die "no checksum $sum_var in versions.env"
  tmpd="$(mktemp -d)"
  tarball="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  retry 3 5 curl -fsSL --max-time 120 -o "$tmpd/$tarball" "https://get.helm.sh/$tarball" || die "cannot download https://get.helm.sh/$tarball"
  echo "$want_sum  $tmpd/$tarball" | sha256sum -c --quiet - >/dev/null 2>&1 || die "checksum mismatch for $tarball (expected $want_sum)"
  tar -xzf "$tmpd/$tarball" -C "$tmpd" "linux-${ARCH}/helm"
  install -m 0755 "$tmpd/linux-${ARCH}/helm" "$helm_bin"
  rm -rf "$tmpd"
  changed "helm $HELM_VERSION installed to $helm_bin (sha256 verified)"
fi
other_helm="$(command -v helm || true)"
[[ "$other_helm" == "$helm_bin" ]] || warn "'helm' in PATH is $other_helm, not $helm_bin; the deployment uses whatever comes first in PATH"
