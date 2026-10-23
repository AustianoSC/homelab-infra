# MetalLB

Gives `LoadBalancer` Services real LAN addresses (k3s' built-in `servicelb` is
disabled). Layer 2 mode, two pools: see `pools.yaml`.

Chart version: **0.16.1** (MetalLB v0.16.1).

Deployed by Argo CD: `kubernetes/argocd/applications/metallb.yaml` installs the
chart with `values.yaml`, and `metallb-pools.yaml` applies `pools.yaml`. To
upgrade, change `targetRevision` in the first and merge to `main`.
