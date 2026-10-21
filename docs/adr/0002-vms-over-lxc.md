# 0002. Full VMs, not LXC containers, for the nodes

Status: Accepted (2026-10)

## Context

LXC containers on Proxmox use less memory and start faster than VMs, which
matters on a 32GB host.

## Decision

Use full VMs for every k3s node.

## Consequences

- LXC containers share the host's kernel. Running k3s in one means either a
  privileged container or loosened AppArmor, cgroup and device settings, so a
  mistake in a pod is much closer to the Proxmox host.
- A VM gets its own kernel, which k3s, containerd and CNI expect, and the
  cloud-init flow used here applies to VMs as it does to any cloud.
- A VM's disks and memory are plain accounting, with no surprises from
  container-in-container limits.
- The price is a guest OS per node, a few hundred MB each, which fits the
  memory budget (see the plan).
