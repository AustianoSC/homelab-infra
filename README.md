# homelab-infra

Infrastructure-as-code for a single-node Proxmox homelab, built as a platform
engineering portfolio project. The goal is a k3s cluster provisioned with
OpenTofu and configured with Ansible, managed by GitOps, running game servers
for friends and CI/CD for my personal projects. This repository is the record
of getting there.

## Hardware

| Component | Spec | Proxmox storage |
| --- | --- | --- |
| CPU | Intel i9-12900K (8 P-cores + 8 E-cores, 24 threads) | |
| RAM | 32GB DDR5 | |
| GPU | NVIDIA GTX 1080 (8GB, reserved for later passthrough) | |
| Boot | 500GB SATA SSD (Proxmox VE 9) | `local`, `local-lvm` |
| Fast storage | 1TB NVMe (k3s node boot disks) | `nvme-ssd-1tb` |
| Bulk storage | 1TB SATA SSD (application data) | `sata-ssd-1tb` |
| Backups | 2TB 7200rpm HDD | `hdd-2tb` |

The 32GB memory ceiling is the defining constraint of this project and drives
most of the design decisions recorded here.

## Current state

- **Running:** a Palworld dedicated server on a hand-built Proxmox VM, reached
  by friends over WireGuard. The VM is shut down, with a full backup on
  `hdd-2tb`, until the server moves onto the cluster. See
  [apps/palworld](apps/palworld).
- **In progress:** phase 1, the k3s cluster. See the
  [plan](docs/plans/phase-1-cluster.md) and
  [checklist](docs/plans/phase-1-checklist.md).

The Palworld VM is intentionally not managed by OpenTofu. It is a disposable
artifact that gets deleted when the workload moves onto Kubernetes, so the
durable piece is the compose file, which translates directly into a StatefulSet.

## Roadmap

- [x] Palworld server on a VM, reachable over WireGuard
- [ ] OpenTofu with client-side encrypted state in a versioned S3 bucket
- [ ] k3s cluster provisioned by OpenTofu, configured by Ansible
- [ ] GitOps with Argo CD
- [ ] Minecraft server on the cluster
- [ ] Migrate Palworld from the VM onto the cluster
- [ ] Router WireGuard peers and firewall rules managed by Ansible
- [ ] Observability (VictoriaMetrics + Grafana)
- [ ] Self-hosted GitHub Actions runners

## Repository layout

```
apps/        Workloads that run outside the cluster today (Docker Compose)
docs/plans/  Phase plans and checklists
```

Planned as phase 1 lands:

```
tofu/        OpenTofu: S3 state bucket bootstrap, Proxmox VMs for the k3s nodes
ansible/     Ansible: node baseline and k3s install
kubernetes/  Manifests and Helm values, later managed by Argo CD
docs/adr/    Architecture decision records
```

## Secrets

No secrets live in this repository, encrypted or otherwise. Files ending in
`.env.tpl` contain 1Password secret references (`op://vault/item/field`) and are
safe to commit. The real values are injected at run time, or generated into a
gitignored `.env`:

```bash
op run --env-file=.env.tpl -- <command>
op inject -i .env.tpl -o .env
```

Once the cluster exists, External Secrets Operator with the 1Password provider
will fill the same role for in-cluster workloads.

## Networking

Nothing is exposed on the public IP except the router's WireGuard listener.
Administrative access and friends' game traffic both arrive over WireGuard
terminated on the router (a GL.iNet Flint 3). Friends' peers are restricted by
the router firewall to the DNS server and the game servers, so they can't reach
the rest of the LAN.

On the cluster, every game server gets a fixed address from a dedicated
`192.168.8.48/29` block. Friends' `AllowedIPs` and the firewall rule name that
block rather than individual servers, so adding a game needs no change on
either side.

Internal name resolution uses `.internal` via AdGuard Home on the router (not
`.local`, which macOS reserves for mDNS and refuses to resolve over unicast
DNS).

| Name | Address |
| --- | --- |
| Router, AdGuard DNS (`router.internal`) | `192.168.8.1` |
| Proxmox host (`homelab.internal`) | `192.168.8.150` |
| Palworld VM (`palworld.internal`, shut down) | `192.168.8.119` |
| k3s nodes (planned) | `192.168.8.11` - `192.168.8.13` |
| MetalLB `games` pool (planned) | `192.168.8.48/29` (`.48` - `.55`): Palworld `.48`, Minecraft `.49` |
| MetalLB `general` pool (planned) | `192.168.8.56/29` (`.56` - `.63`): Traefik, web UIs |
