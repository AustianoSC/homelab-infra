# 0007. Pull-based GitOps with Argo CD

Status: Accepted (2026-10). Built in phase 2; see
[the plan](../plans/phase-2-gitops-palworld.md).

## Context

This repository is meant to be public, and personal projects need to be deployed
to the cluster. A push model (a CI runner with cluster credentials) would mean
credentials that untrusted code, such as a pull request from a fork, could
reach.

## Decision

Deploy by pull. Argo CD runs in the cluster and watches this repo; Argo CD
Image Updater bumps image tags in Git. CI, here and in the application repos,
builds and tests but holds no credentials for the cluster. GitOps configuration
stays in this repo under `kubernetes/{infra,apps,argocd}`.

Argo CD reads the repo over HTTPS with no credentials, because the repo is
public: there is no key to store, rotate or leak. (A private repo would need a
read-only deploy key, which protects the repo's contents; with nothing secret in
a public repo there is nothing for it to protect.) A root "app of apps"
(`kubernetes/argocd/root-app.yaml`) creates one Application per file in
`kubernetes/argocd/applications`, so adding a workload is adding a file.

Self-hosted GitHub Actions runners are not used on public repositories.

## Consequences

- Nothing outside the LAN can push changes to the cluster, and the cluster
  needs no inbound connection from the internet.
- Making the repo public is safe provided it holds no secrets. Secrets stay in
  1Password. The cluster reads what it needs through External Secrets
  ([ADR 0008](0008-external-secrets-for-1password.md)), so nothing is committed
  and only one read-only token is loaded by hand.
- The Git history is the audit log of what was deployed.
- Argo CD itself is the one thing installed by hand (`make argocd`). It manages
  MetalLB and Palworld, but not itself, so upgrading Argo CD means changing
  `ARGOCD_CHART_VERSION` in the Makefile and re-running that target.
- Changes land within about three minutes, the interval at which Argo CD polls
  Git, unless a refresh is triggered by hand.
- CI in this repo is deliberately lint-only (`.github/workflows/lint.yml`). It
  has no credentials and never runs `apply`.
