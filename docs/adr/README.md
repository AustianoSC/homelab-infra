# Architecture decision records

Short records of the decisions that shaped this repo: what was chosen, what it
was chosen over, and what it costs. Newer records can supersede older ones;
they are never rewritten to hide a change of mind.

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-k3s-over-talos.md) | k3s on Ubuntu VMs, not Talos | Accepted |
| [0002](0002-vms-over-lxc.md) | Full VMs, not LXC containers, for the nodes | Accepted |
| [0003](0003-one-control-plane.md) | One control plane and two workers | Accepted |
| [0004](0004-encrypted-state-in-s3.md) | OpenTofu state in S3, encrypted client-side | Accepted |
| [0005](0005-metallb-over-servicelb.md) | MetalLB instead of k3s' servicelb | Accepted |
| [0006](0006-local-path-over-longhorn.md) | local-path storage instead of Longhorn | Accepted |
| [0007](0007-pull-based-gitops.md) | Pull-based GitOps with Argo CD | Accepted |
| [0008](0008-external-secrets-for-1password.md) | External Secrets Operator for 1Password secrets | Accepted |
