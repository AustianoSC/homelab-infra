# 0008. External Secrets Operator for 1Password secrets

Status: Accepted (2026-10). Built in phase 3; see
[the plan](../plans/phase-3-external-secrets.md). It replaced the
`make palworld-secret` target that [ADR 0007](0007-pull-based-gitops.md) first
relied on.

## Context

Everything on the cluster is deployed from Git, but secrets can't be. The repo
is public, so no secret may be in it, encrypted or not. Today one secret
(Palworld's passwords) is created by a `make` target that reads 1Password. That
is one manual step per secret, and it gets worse as personal projects arrive:
every app would need its own target, and a rebuilt cluster would need each one
run again.

1Password is already the source of truth for every other secret in this repo
(the Proxmox token, the state passphrase, the join token).

## Decision

Run External Secrets Operator in the cluster, with its 1Password SDK provider.
A `ClusterSecretStore` points it at one vault, `homelab-k8s`, using a service
account token with read-only access to that vault and an expiry. Each workload
declares an `ExternalSecret` next to its other manifests, naming the 1Password
item and field to copy; ESO creates the Kubernetes `Secret`. The manifests hold
references only, so they are safe in a public repo.

The service account token is the one secret still loaded by hand, with
`make eso-token`, from 1Password through a pipe, never touching disk or a
command line.

## Alternatives

- **The current `make` targets.** Simple, and fine for one secret. One step per
  secret and per app is what this replaces.
- **1Password's own Kubernetes operator.** It has traditionally needed a
  Connect server running in the cluster, which is more to run and a second
  credential to look after. ESO's SDK provider needs only the service account
  token, and ESO isn't tied to one vendor.
- **Sealed Secrets or SOPS.** Encrypted secrets live in Git. That works, but
  makes the repo a second home for secrets, with its own key to protect and
  back up, while 1Password already holds the rest. It also puts ciphertext in a
  public repo for good.

## Consequences

- Adding a secret to an app is a manifest in Git and an item in 1Password. No
  `make` target, no manual step. A rebuild restores them all after one
  `make eso-token`.
- The service account token can read everything in `homelab-k8s`, and every
  namespace can use the one store. That is why the vault holds only what the
  cluster needs, and why the Proxmox and state secrets stay in `homelab`.
- The token expires, and has to be renewed by hand before it does.
- Secrets reach pods only when a pod starts, so a changed password needs a
  restart. Reloader can automate that later.
- If 1Password is unreachable, existing Secrets stay; only changes stop.
- ESO is another operator to upgrade, and its CRDs are large, so Argo CD syncs
  it with server-side apply.
