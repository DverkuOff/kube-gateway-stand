# kubeadm configuration for a single-node cluster. Rendered by scripts/20-cluster.sh with envsubst
# (substituted variables: NODE_IP, POD_CIDR, SVC_CIDR, KUBERNETES_VERSION).
# Reference: https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  kubeletExtraArgs:
    - name: node-ip
      value: ${NODE_IP}
  # Single node: workloads run on the control-plane node.
  taints: []
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: kubernetes
kubernetesVersion: ${KUBERNETES_VERSION}
networking:
  dnsDomain: cluster.local
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SVC_CIDR}
apiServer:
  extraArgs:
    # DenyServiceExternalIPs: Service.spec.externalIPs is not used here (CVE-2020-8554).
    - name: enable-admission-plugins
      value: NodeRestriction,DenyServiceExternalIPs
# Metrics endpoints of controller-manager (10257) and scheduler (10259) are HTTPS with
# authentication and authorization; bind them to the node address so Prometheus can scrape them.
# etcd metrics stay on the kubeadm default http://127.0.0.1:2381 (plain HTTP, not exposed).
controllerManager:
  extraArgs:
    - name: bind-address
      value: ${NODE_IP}
scheduler:
  extraArgs:
    - name: bind-address
      value: ${NODE_IP}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
# Explicit mode; metrics stay on the default 127.0.0.1:10249.
mode: iptables
