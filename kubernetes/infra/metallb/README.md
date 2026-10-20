# MetalLB

Gives `LoadBalancer` Services real LAN addresses (k3s' built-in `servicelb` is
disabled). Layer 2 mode, two pools: see `pools.yaml`.

Chart version: **0.16.1** (MetalLB v0.16.1).

## Install or upgrade

```bash
export KUBECONFIG=~/.kube/homelab.yaml
helm repo add metallb https://metallb.github.io/metallb
helm upgrade --install metallb metallb/metallb \
  --version 0.16.1 -n metallb-system --create-namespace \
  -f kubernetes/infra/metallb/values.yaml --wait
kubectl apply -f kubernetes/infra/metallb/pools.yaml
```

The pools are applied after the chart because they use CRDs the chart installs,
and the chart's webhook must be ready first (`--wait` covers that).
