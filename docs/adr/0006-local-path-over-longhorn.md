# 0006. local-path storage instead of Longhorn

Status: Accepted (2026-10)

## Context

Stateful workloads (game worlds) need persistent volumes. Longhorn is the
usual choice for replicated storage in a homelab.

## Decision

Use k3s' built-in local-path provisioner. Each worker has a second virtual
disk, on the SATA SSD, mounted at `/var/lib/rancher/k3s/storage`, so volumes
live on the data disk and not the OS disk.

## Consequences

- Longhorn replicates volumes across nodes, but all nodes share one physical
  disk, so replication would protect against nothing a single disk failure
  doesn't also take out, while costing memory and write amplification.
- Volumes are pinned to the node they were created on. A pod with a volume
  can't move if its node is lost, which is acceptable here.
- Protection comes from backups, not replication: Proxmox backups of the VMs
  to the HDD, and later a scheduled copy of game saves.
- Revisit if a second physical host is ever added.
