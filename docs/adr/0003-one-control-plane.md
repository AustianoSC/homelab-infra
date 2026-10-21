# 0003. One control plane and two workers

Status: Accepted (2026-10)

## Context

A highly available k3s control plane needs three servers. All three nodes
would run on one physical host.

## Decision

One server (`k3s-cp-1`, 3GB, tainted so it only runs control-plane
components) and two agents: `k3s-worker-1` (16GB, sized for Palworld) and
`k3s-worker-2` (8GB, for Minecraft and everything else).

## Consequences

- Three servers would cost about 6GB more for HA the hardware can't provide:
  one power supply, one disk set and one hypervisor remain the single point of
  failure.
- Two workers still demonstrate what a single node can't: scheduling across
  nodes, taints and tolerations, and draining a node for maintenance.
- The control plane uses embedded etcd (`cluster-init`) rather than SQLite, so
  more servers can be added later without migrating the datastore.
- If the control plane VM is lost, running workloads keep running but nothing
  can be changed until it is rebuilt. The whole cluster is rebuilt from this
  repo with `make rebuild`.
