#!/usr/bin/env bash
# Remove the Kubernetes cluster created by deploy.sh from this host:  sudo ./scripts/destroy.sh
# Asks for confirmation (YES=1 skips it). Installed packages (containerd, kubeadm, helm...) and
# the node settings of stage 10 stay, so ./deploy.sh can create a fresh cluster right after.
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_error $LINENO "$BASH_COMMAND"' ERR
require_root

ADMIN_CONF=/etc/kubernetes/admin.conf

if [[ "${YES:-}" != 1 ]]; then
  [[ -t 0 ]] || die "refusing to remove the cluster without confirmation: run with YES=1 (make destroy YES=1)"
  printf 'This removes the Kubernetes cluster and all its data from this host (kubeadm reset).\n'
  read -r -p "Type 'yes' to continue: " answer
  [[ "$answer" == yes ]] || die "aborted, nothing was changed"
fi
trap summary EXIT

step "destroy: kubeconfig files"
# Delete a user's ~/.kube/config only when it is exactly our admin kubeconfig.
user="$(invoking_user)"
homes=(/root)
user_home="$(getent passwd "$user" | cut -d: -f6 || true)"
[[ -n "$user_home" && "$user_home" != /root ]] && homes+=("$user_home")
for h in "${homes[@]}"; do
  f="$h/.kube/config"
  if [[ ! -f "$f" ]]; then
    continue
  elif [[ -f "$ADMIN_CONF" ]] && cmp -s "$f" "$ADMIN_CONF"; then
    rm -f "$f"
    changed "removed $f (copy of the cluster admin kubeconfig)"
  else
    ok "kept $f (not the admin kubeconfig of this cluster)"
  fi
done

step "destroy: pods and kubeadm state"
if systemctl is-active --quiet kubelet; then
  systemctl stop kubelet
  changed "kubelet stopped (the next deploy starts it again)"
fi
# Remove all pod sandboxes before 'kubeadm reset'. Calico's CNI plugin cannot tear down pod
# networks once the API server is gone, and containerd refuses to remove a sandbox without a
# loaded CNI config. A temporary loopback-only config lets containerd remove them cleanly.
CLEANUP_CNI=/etc/cni/net.d/00-kgs-cleanup.conflist
rm -f /etc/cni/net.d/10-calico.conflist /etc/cni/net.d/calico-kubeconfig
if have crictl && systemctl is-active --quiet containerd && [[ -n "$(crictl pods -q 2>/dev/null)" ]]; then
  install -D -m 0644 /dev/stdin "$CLEANUP_CNI" <<<'{"cniVersion": "1.0.0", "name": "kgs-cleanup", "plugins": [{"type": "loopback"}]}'
  retry 10 2 crictl rmp -f -a >/dev/null 2>&1 || warn "some pod sandboxes could not be removed (crictl pods)"
  changed "removed all pod sandboxes"
fi
rm -f "$CLEANUP_CNI"
kubeadm_state() {
  compgen -G '/etc/kubernetes/manifests/*.yaml' >/dev/null || compgen -G '/etc/kubernetes/*.conf' >/dev/null ||
    compgen -G '/etc/kubernetes/pki/*' >/dev/null || [[ -d /var/lib/etcd/member || -f /var/lib/kubelet/config.yaml ]]
}
if have kubeadm && kubeadm_state; then
  kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock >/dev/null 2>&1 ||
    die "kubeadm reset failed; run 'sudo kubeadm reset -f' to see the error"
  changed "kubeadm reset"
else
  ok "no kubeadm state"
fi
systemctl stop kubelet 2>/dev/null || true

step "destroy: CNI and Calico state"
# calico-node mounts a cgroup2 hierarchy under /run/calico.
while read -r mnt; do
  [[ -n "$mnt" ]] || continue
  umount "$mnt" && changed "unmounted $mnt"
done < <(findmnt -rn -o TARGET | grep -E '^/(var/)?run/calico(/|$)' | sort -r || true)
for p in /etc/cni/net.d/10-calico.conflist /etc/cni/net.d/calico-kubeconfig /var/lib/calico /run/calico \
  /var/log/calico /run/nodeagent /opt/local-path-provisioner /var/lib/fluentd "$STATE_DIR"; do
  if [[ -e "$p" ]]; then
    rm -rf "$p"
    changed "removed $p"
  fi
done
while read -r ns; do
  [[ -n "$ns" ]] || continue
  ip netns delete "$ns" 2>/dev/null && changed "removed network namespace $ns"
done < <(ip netns list 2>/dev/null | awk '$1 ~ /^cni-/ { print $1 }')
while read -r link; do
  [[ -n "$link" ]] || continue
  ip link delete "$link" 2>/dev/null && changed "removed interface $link"
done < <(ip -o link show | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }' | grep -E '^(cali|vxlan\.calico$|vxlan-v6\.calico$|tunl0$)' || true)
# Calico installs its routes with protocol 80 (blackhole routes for pod address blocks).
if [[ -n "$(ip -4 route show proto 80 2>/dev/null)" ]]; then
  ip -4 route flush proto 80
  changed "removed Calico routes"
fi
if have nft; then
  while read -r family name; do
    [[ -n "$name" ]] || continue
    nft delete table "$family" "$name" && changed "removed nftables table $family $name"
  done < <(nft list tables 2>/dev/null | awk '$1 == "table" && $3 ~ /^(calico|kube-proxy)/ { print $2, $3 }')
fi

step "destroy: iptables rules of kube-proxy, kubelet and Calico"
# Only chains named KUBE-* and cali-* and the rules that jump to them are removed;
# every other rule (Docker, ufw, libvirt...) is restored unchanged.
clean_iptables() {
  local save=$1 restore=$2 table dump filtered
  have "$save" || return 0
  for table in filter nat mangle raw; do
    dump="$("$save" -t "$table" 2>/dev/null)" || continue
    grep -Eq '(^:|-A |-[jg] )(KUBE-|cali-)' <<<"$dump" || continue
    filtered="$(grep -Ev '^:(KUBE-|cali-)|^-A (KUBE-|cali-)|-[jg] (KUBE-|cali-)' <<<"$dump")"
    printf '%s\n' "$filtered" | "$restore" -T "$table" ||
      die "$restore failed for table $table; inspect with: $save -t $table"
    changed "$save: removed KUBE-/cali- chains from table $table"
  done
}
clean_iptables iptables-save iptables-restore
clean_iptables ip6tables-save ip6tables-restore
if have ipset; then
  mapfile -t sets < <(ipset list -n 2>/dev/null | grep -E '^cali' || true)
  for s in "${sets[@]}"; do
    if ipset destroy "$s" 2>/dev/null; then changed "removed ipset $s"; fi
  done
fi

info "packages and node settings are kept; ./deploy.sh creates a new cluster"
