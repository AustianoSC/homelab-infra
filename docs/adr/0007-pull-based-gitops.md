# 0007. Pull-based GitOps with Argo CD

Status: Accepted (2026-10). Not yet built; this is the next phase.

## Context

This repository is public, and personal projects need to be deployed to the
cluster. A push model (a CI runner with cluster credentials) would mean
credentials that untrusted code, such as a pull request from a fork, could
reach.

## Decision

Deploy by pull. Argo CD runs in the cluster and watches this repo; Argo CD
Image Updater bumps image tags in Git. CI, here and in the application repos,
builds and tests but holds no credentials for the cluster. GitOps configuration
stays in this repo under `kubernetes/{infra,apps,argocd}`.

Self-hosted GitHub Actions runners are not used on public repositories.

## Consequences

- Nothing outside the LAN can push changes to the cluster, and the cluster
  needs no inbound connection from the internet.
- Making the repo public is safe provided it holds no secrets. Secrets stay in
  1Password and, later, reach the cluster through External Secrets.
- The Git history is the audit log of what was deployed.
- Until Argo CD exists, MetalLB is installed by hand (`make metallb`). Moving
  it under Argo CD is the first task of the next phase.
- CI in this repo is deliberately lint-only (`.github/workflows/lint.yml`). It
  has no credentials and never runs `apply`.
