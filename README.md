# homelab-infra

Infrastructure-as-code for a single-node Proxmox homelab, built as a platform
engineering portfolio project. The long-term goal is a k3s cluster provisioned
with OpenTofu and Ansible, managed by GitOps, running CI/CD for my personal
projects. This repository is the record of getting there.

## Hardware

| Component | Spec |
| --- | --- |
| CPU | Intel i9-12900K (8 P-cores + 8 E-cores, 24 threads) |
| RAM | 32GB DDR5 |
| GPU | NVIDIA GTX 1080 (8GB, reserved for later passthrough) |
| Boot | 500GB SATA SSD (Proxmox VE) |
| Fast storage | 1TB NVMe (future k3s node disks) |
| Bulk storage | 1TB SATA SSD (application data) |
| Backups | 2TB 7200rpm HDD |

The 32GB memory ceiling is the defining constraint of this project and drives
most of the design decisions recorded here.

## Current state

Phase 1: a Palworld dedicated server running in a Proxmox VM, exposed through a
playit.gg tunnel. See [apps/palworld](apps/palworld).

The VM itself is intentionally not managed by OpenTofu. It is a disposable
artifact that gets deleted when the workload moves onto Kubernetes, so the
durable piece is the compose file, which translates directly into a StatefulSet.

## Roadmap

- [x] Palworld server on a VM, tunneled via playit.gg
- [ ] OpenTofu with encrypted remote state on Cloudflare R2
- [ ] k3s cluster provisioned by OpenTofu, configured by Ansible
- [ ] GitOps with Argo CD
- [ ] Migrate Palworld from the VM onto the cluster
- [ ] Observability (VictoriaMetrics + Grafana)
- [ ] Self-hosted GitHub Actions runners

## Secrets

No secrets live in this repository, encrypted or otherwise. Files ending in
`.env.tpl` contain 1Password secret references (`op://vault/item/field`) and are
safe to commit. The real `.env` is generated locally and gitignored:

```bash
op inject -i .env.tpl -o .env
```

Once the cluster exists, External Secrets Operator with the 1Password provider
will fill the same role for in-cluster workloads.

## Networking

Nothing is exposed inbound on the public IP. Administrative access arrives over
WireGuard terminated on the router; game traffic leaves through an outbound
playit.gg tunnel. Internal name resolution uses `.internal` via AdGuard Home
(not `.local`, which macOS reserves for mDNS and refuses to resolve over
unicast DNS).
