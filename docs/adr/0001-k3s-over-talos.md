# 0001. k3s on Ubuntu VMs, not Talos

Status: Accepted (2026-10)

## Context

The cluster has to fit in 32GB of RAM alongside game servers, and the
project's purpose is to show infrastructure built with OpenTofu and Ansible.

## Decision

Run k3s on Ubuntu 24.04 cloud-image VMs. OpenTofu creates the VMs; Ansible
configures them and installs k3s, pinned to one version.

## Consequences

- k3s is light: the control plane runs in 3GB.
- Ansible has real work to do (node baseline, k3s install, upgrades). Talos
  has no SSH and is configured through its own API, so it would have replaced
  Ansible and left half of the project's stated goal with nothing to show.
- The nodes are ordinary Linux machines, so debugging is `ssh` and `journalctl`.
- The cost is that the OS needs patching, which Talos's immutable image
  avoids. Talos is a reasonable later experiment on a separate cluster.
