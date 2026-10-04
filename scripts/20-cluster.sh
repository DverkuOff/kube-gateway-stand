#!/usr/bin/env bash
# Stage 20-cluster — kubeadm init, kubeconfig, Calico, local-path storage
# Owner: track A. Sourced by deploy.sh; can also run alone: sudo ./scripts/20-cluster.sh
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_standalone_init

ADMIN_CONF=/etc/kubernetes/admin.conf
# Chart archives of the Calico release (the same charts as the https://docs.tigera.io/calico/charts
# repository, whose index.yaml is slow to download from some networks).
CALICO_CHARTS="https://github.com/projectcalico/calico/releases/download/${CALICO_VERSION}"

# ---------- cluster state (same rules as 00-preflight.sh) ----------
kgs_kubectl() { kubectl --kubeconfig "$ADMIN_CONF" --request-timeout=5s "$@"; }
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

have kubeadm || die "kubeadm is not installed: run stage 10-node first (sudo ./deploy.sh)"
have helm || die "helm is not installed: run stage 10-node first (sudo ./deploy.sh)"
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"

# ---------- kubeadm init ----------
step "cluster: control plane"
kubeadm_cfg="$STATE_DIR/kubeadm-config.yaml"
# shellcheck disable=SC2016  # envsubst variable list, expanded by envsubst itself
write_file "$kubeadm_cfg" 0600 < <(render_template "$REPO_ROOT/templates/kubeadm-config.yaml.tpl" '${NODE_IP} ${POD_CIDR} ${SVC_CIDR} ${KUBERNETES_VERSION}')

if cluster_ready; then
  live_version="$(kc version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty' || true)"
  if [[ -n "$live_version" && "$live_version" != "$KUBERNETES_VERSION" ]]; then
    warn "cluster runs $live_version, versions.env pins $KUBERNETES_VERSION; upgrades are not automated (make destroy && make deploy)"
  fi
  ok "cluster already initialized ($live_version)"
elif cluster_traces; then
  die "found traces of a previous 'kubeadm init', but the cluster is not ready. Nothing was changed. Run 'make destroy' (sudo YES=1 ./scripts/destroy.sh) and deploy again."
else
  kubeadm config validate --config "$kubeadm_cfg" >/dev/null || die "kubeadm rejected $kubeadm_cfg (see the message above)"
  info "pulling control-plane images (registry.k8s.io)"
  retry 3 10 kubeadm config images pull --config "$kubeadm_cfg" >/dev/null ||
    die "cannot pull control-plane images from registry.k8s.io; check network access"
  info "kubeadm init (log: $STATE_DIR/kubeadm-init.log)"
  if ! kubeadm init --config "$kubeadm_cfg" --skip-token-print >"$STATE_DIR/kubeadm-init.log" 2>&1; then
    tail -n 20 "$STATE_DIR/kubeadm-init.log" >&2
    die "kubeadm init failed (full log: $STATE_DIR/kubeadm-init.log). Fix the cause, then 'make destroy' and deploy again."
  fi
  changed "kubeadm init: Kubernetes $KUBERNETES_VERSION at https://$NODE_IP:6443"
fi
chmod 0600 "$ADMIN_CONF"
wait_for 120 "API server /readyz" cluster_ready

# ---------- kubeconfig for the user who ran sudo ----------
step "cluster: kubeconfig"
user="$(invoking_user)"
home="$(getent passwd "$user" | cut -d: -f6)"
if [[ -z "$home" || ! -d "$home" ]]; then
  warn "cannot find the home directory of '$user'; use: sudo kubectl --kubeconfig $ADMIN_CONF ..."
else
  group="$(id -gn "$user")"
  kdir="$home/.kube" kcfg="$home/.kube/config"
  if [[ ! -d "$kdir" ]]; then
    install -d -m 0700 -o "$user" -g "$group" "$kdir"
    changed "$kdir created"
  fi
  if [[ "$(stat -c %a "$kdir")" != 700 ]]; then
    chmod 0700 "$kdir"
    changed "$kdir mode 0700"
  fi
  if [[ -f "$kcfg" ]] && cmp -s "$kcfg" "$ADMIN_CONF"; then
    ok "$kcfg is the cluster admin kubeconfig"
  else
    if [[ -f "$kcfg" ]]; then
      # A kubeconfig of an earlier cluster on this host (same API address) is replaced; anything else is kept as a backup.
      if ! grep -qE "server: https://${NODE_IP//./\\.}:6443\$" "$kcfg" || ! grep -q 'kubernetes-admin' "$kcfg"; then
        backup="$kcfg.bak-kgs-$(date +%Y%m%d%H%M%S)"
        cp -a "$kcfg" "$backup"
        info "existing $kcfg saved as $backup"
      fi
    fi
    install -m 0600 -o "$user" -g "$group" "$ADMIN_CONF" "$kcfg"
    changed "$kcfg (admin kubeconfig for $user)"
  fi
  chown "$user:$group" "$kcfg"
  chmod 0600 "$kcfg"
fi

# ---------- single node: allow workloads on the control plane ----------
step "cluster: node"
taints="$(kc get nodes -o jsonpath='{range .items[*]}{.spec.taints[*].key}{" "}{end}')"
if [[ " $taints " == *" node-role.kubernetes.io/control-plane "* ]]; then
  kc taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null
  changed "removed taint node-role.kubernetes.io/control-plane"
else
  ok "no control-plane taint"
fi
labels="$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.labels}{end}')"
if [[ "$labels" == *'node.kubernetes.io/exclude-from-external-load-balancers'* ]]; then
  kc label nodes --all node.kubernetes.io/exclude-from-external-load-balancers- >/dev/null
  changed "removed label node.kubernetes.io/exclude-from-external-load-balancers"
else
  ok "no exclude-from-external-load-balancers label"
fi

# ---------- Calico ----------
step "cluster: Calico $CALICO_VERSION"
# Since Calico 3.32 the CRDs ship in a separate chart; they are applied server-side (too big for
# client-side apply), as the tigera-operator chart README describes.
crds="$STATE_DIR/manifests/calico-crds-${CALICO_VERSION}.yaml"
if [[ ! -s "$crds" ]]; then
  mkdir -p "$(dirname "$crds")"
  retry 3 10 helm template calico-crds "$CALICO_CHARTS/crd.projectcalico.org.v1-${CALICO_VERSION}.tgz" >"$crds.tmp" ||
    die "cannot download the Calico CRD chart from $CALICO_CHARTS"
  mv "$crds.tmp" "$crds"
fi
kapply "$crds"
# --force-conflicts: the operator fills defaults into the Installation spec (field manager "operator"),
# so a later upgrade of changed values would otherwise fail with a server-side apply conflict.
helm_release calico tigera-operator "$CALICO_CHARTS/tigera-operator-${CALICO_VERSION}.tgz" "$CALICO_VERSION" \
  --force-conflicts \
  -f "$REPO_ROOT/values/calico.yaml" \
  --set "installation.calicoNetwork.ipPools[0].cidr=$POD_CIDR"

# Every component the operator reports on (calico, apiserver, ippools, tiers) must be Available.
calico_available() {
  local s
  s="$(kc get tigerastatus -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Available")].status}{" "}{end}' 2>/dev/null)"
  [[ " $s " == *" calico=True "* && " $s " == *" apiserver=True "* && " $s " != *"=False "* && " $s " != *"= "* ]]
}
if calico_available; then
  ok "Calico Available (tigerastatus)"
else
  info "waiting for Calico to become Available (up to 10 min)"
  wait_for 600 "all tigerastatus Available (kubectl get tigerastatus; kubectl -n calico-system get pods)" calico_available
  ok "Calico Available (tigerastatus)"
fi
kc wait --for=condition=Ready node --all --timeout=300s >/dev/null || die "node is not Ready after 5 min (kubectl describe node)"
ok "node Ready"

# ---------- local-path storage ----------
step "cluster: local-path-provisioner $LOCAL_PATH_VERSION"
lp_manifest="$REPO_ROOT/manifests/local-path/local-path-storage.yaml"
grep -q "rancher/local-path-provisioner:${LOCAL_PATH_VERSION}\$" "$lp_manifest" ||
  die "$lp_manifest does not match LOCAL_PATH_VERSION=$LOCAL_PATH_VERSION; replace it with the manifest of that release"
kapply "$lp_manifest"
default_sc="$(kc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}')"
if [[ " $default_sc " == *" local-path "* ]]; then
  ok "StorageClass local-path is the default"
else
  kc annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null
  changed "StorageClass local-path set as default"
fi
for sc in $default_sc; do
  [[ "$sc" == local-path ]] || warn "StorageClass $sc is also marked as default; PVCs without storageClassName may land there"
done
kc -n local-path-storage wait --for=condition=Available deployment/local-path-provisioner --timeout=300s >/dev/null ||
  die "local-path-provisioner is not Available (kubectl -n local-path-storage get pods)"
ok "local-path-provisioner Available"

# ---------- cluster DNS ----------
step "cluster: CoreDNS"
kc -n kube-system wait --for=condition=Available deployment/coredns --timeout=300s >/dev/null ||
  die "CoreDNS is not Available (kubectl -n kube-system get pods -l k8s-app=kube-dns)"
ok "CoreDNS Available"
