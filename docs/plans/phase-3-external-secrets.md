# Phase 3: Secrets from 1Password with External Secrets

Goal: a workload gets its secrets by declaring them in Git, with no `make`
target and no manual step per app. "Done" means Palworld's passwords reach the
cluster through External Secrets, `make palworld-secret` is gone, and the next
app that needs a secret only adds a manifest.

Do this **after** phase 2 is finished and Palworld has run stably on the
cluster for a while. It touches the one secret Palworld depends on, and the
cutover shouldn't have a second moving part in it. The decision is recorded in
[ADR 0008](../adr/0008-external-secrets-for-1password.md).

## Decisions

| Topic | Decision | Why |
| --- | --- | --- |
| Operator | External Secrets Operator (ESO), chart pinned in the Application | Open source and not tied to 1Password, so the skill carries over to Vault or AWS |
| Provider | ESO's `onepasswordSDK` provider with a service account token | No Connect server to run: no extra pods, credentials file or token to look after |
| Vault | A new vault, `homelab-k8s`, holding only what the cluster needs | The token can read everything in its vault, so keep the vault small. The `homelab` vault has the Proxmox token and the state passphrase |
| Access | Service account with **read-only** access to `homelab-k8s`, with an expiry | The cluster never needs to write, and a leaked token stops working |
| Store | One `ClusterSecretStore` named `onepassword` | One store for every namespace. Any ExternalSecret in the cluster can read the vault, which is fine for one user and a small vault |
| Refresh | `refreshInterval: 1h` per ExternalSecret | Service accounts have request limits, and passwords don't change by the minute |
| Bootstrap | The service account token is the one secret loaded by hand: `make eso-token` | Something has to unlock the rest. Same `op read` pattern as today, never on disk or in argv |
| Restarts | Not automated at first | A new password only reaches a pod when it restarts. Palworld's passwords rarely change, so a manual restart is enough. Add Reloader if that stops being true |

## What changes in the repo

| Path | Change |
| --- | --- |
| `kubernetes/argocd/applications/external-secrets.yaml` | New: the upstream chart, with `ServerSideApply` for the large CRDs |
| `kubernetes/argocd/applications/external-secrets-config.yaml` | New: syncs the `ClusterSecretStore`, like `metallb-pools` does for MetalLB |
| `kubernetes/infra/external-secrets/values.yaml` | New: chart values (small resource requests, no webhook extras) |
| `kubernetes/infra/external-secrets/cluster-secret-store.yaml` | New: points ESO at the `homelab-k8s` vault |
| `kubernetes/apps/palworld/externalsecret.yaml` | New: builds the `palworld` Secret from two 1Password fields |
| `kubernetes/apps/palworld/.env.tpl` | Deleted |
| `Makefile` | New `eso-token`; `palworld-secret` removed; `up` runs `eso-token` instead of it |
| `docs/bootstrap.md`, `README.md`, ADR 0007 | The secrets sections updated |

## Part 1: 1Password (by hand, once)

- [ ] **1. Create the vault and move Palworld's item.** In the 1Password app,
  create a vault named `homelab-k8s`. Move the `palworld` item (fields
  `server-password` and `admin-password`) from `homelab` into it. Nothing else
  moves. The store is per vault, so ESO can't see anything outside this one.

- [ ] **2. Create the service account.** In 1Password on the web: Developer,
  Infrastructure Secrets, Service Accounts, new. Name it `homelab-eso`, give it
  **read** access to `homelab-k8s` only, and set an expiry (90 days is a
  reasonable start). The token is shown **once**; use the option to save it in
  1Password. Save it as an item `eso-service-account`, field `token`, in the
  `homelab` vault (not in `homelab-k8s`, which the token itself can read).
  The CLI can do the same with `op service-account create`; check its `--help`
  for the current flags.

## Part 2: Deploy ESO

- [ ] **3. Add the token loader to the `Makefile`:**
  ```make
  eso-token: ## Put the 1Password service account token in the cluster
  	$(KUBECTL) create namespace external-secrets --dry-run=client -o yaml | $(KUBECTL) apply -f -
  	op read op://homelab/eso-service-account/token | tr -d '\n' \
  	  | $(KUBECTL) -n external-secrets create secret generic onepassword-sa \
  	      --from-file=token=/dev/stdin --dry-run=client -o yaml \
  	  | $(KUBECTL) apply --server-side -f -
  ```
  Put `eso-token` in `up` before `argocd`, in place of `palworld-secret` once
  step 6 is done. Run it once now: `make eso-token`.

- [ ] **4. Add the two Applications.** Same shape as MetalLB.
  `applications/external-secrets.yaml`: source is the chart
  `https://charts.external-secrets.io`, `chart: external-secrets`, with
  `targetRevision` pinned (2.14.0 was current on 2026-10-23; check before
  pinning), `valueFiles` from `$values/kubernetes/infra/external-secrets/values.yaml`,
  destination namespace `external-secrets`, and the same sync options as
  `metallb.yaml`: `CreateNamespace`, `ServerSideApply` (the CRDs are too big for
  a normal apply), and `retry`. `applications/external-secrets-config.yaml`:
  path `kubernetes/infra/external-secrets`, `directory.include:
  cluster-secret-store.yaml`, `SkipDryRunOnMissingResource=true` (the CRD
  doesn't exist yet on the first sync), `retry`.

  The store:
  ```yaml
  apiVersion: external-secrets.io/v1
  kind: ClusterSecretStore
  metadata:
    name: onepassword
  spec:
    provider:
      onepasswordSDK:
        vault: homelab-k8s
        auth:
          serviceAccountSecretRef:
            name: onepassword-sa
            namespace: external-secrets
            key: token
  ```
  Before pushing, check the manifests offline with
  `helm template` and `kubeconform`, as phase 2 did.

- [ ] **5. Push and check.**
  | Check | Command | Expected |
  | --- | --- | --- |
  | Applications | `kubectl -n argocd get applications` | `external-secrets` and `external-secrets-config` Synced and Healthy |
  | Operator | `kubectl -n external-secrets get pods` | Controller, cert controller and webhook Running |
  | Store | `kubectl get clustersecretstore onepassword` | Status `Valid`, Ready `True` |

  If the store isn't `Valid`, read the message with
  `kubectl describe clustersecretstore onepassword`. The usual causes are a
  wrong vault name, a token without access to that vault, or an expired token.

## Part 3: Move Palworld over

- [ ] **6. Replace the hand-made Secret.** Add
  `kubernetes/apps/palworld/externalsecret.yaml`:
  ```yaml
  apiVersion: external-secrets.io/v1
  kind: ExternalSecret
  metadata:
    name: palworld
    namespace: palworld
  spec:
    refreshInterval: 1h
    secretStoreRef:
      kind: ClusterSecretStore
      name: onepassword
    target:
      name: palworld
      creationPolicy: Owner
    data:
      - secretKey: PALWORLD_SERVER_PASSWORD
        remoteRef:
          key: palworld/server-password
      - secretKey: PALWORLD_ADMIN_PASSWORD
        remoteRef:
          key: palworld/admin-password
  ```
  The Secret keeps its name and keys, so the StatefulSet doesn't change.
  `make palworld-secret` created a `palworld` Secret that ESO doesn't own, and
  ESO may refuse to take it over. If so, delete it:
  ```bash
  kubectl -n palworld delete secret palworld
  ```
  ESO recreates it within seconds. The running pod isn't affected, because
  environment variables are copied when a container starts. Don't restart the
  pod until the Secret is back.

- [ ] **7. Check it, including a rotation.**
  | Check | Command | Expected |
  | --- | --- | --- |
  | Synced | `kubectl -n palworld get externalsecret palworld` | Status `SecretSynced`, Ready `True` |
  | Same values | `kubectl -n palworld get secret palworld -o jsonpath='{.data.PALWORLD_SERVER_PASSWORD}' \| base64 -d; echo` | The password from 1Password |
  | Rotation | Change a field on a throwaway item, then `kubectl -n palworld annotate externalsecret palworld force-sync=$(date +%s) --overwrite` | The Secret follows within seconds |

  Do the rotation test on a throwaway item rather than changing a real
  password. Add a temporary second entry to the ExternalSecret, or a temporary
  second ExternalSecret, pointing at it, and remove it afterwards.

- [ ] **8. Remove the old path.** Delete `kubernetes/apps/palworld/.env.tpl`
  and the `palworld-secret` target, drop `palworld-secret` from `up`, and
  update the Makefile `help` text. In the docs, replace the `palworld` row in
  the 1Password table in `docs/bootstrap.md` with the `homelab-k8s` vault and
  the `eso-service-account` item, change the secrets paragraph in `README.md`,
  and change the sentence in ADR 0007 that says `make` loads Palworld's
  passwords. Mark ADR 0008 Accepted.

## Rolling back

Delete the Palworld `ExternalSecret` first (or ESO keeps overwriting the
Secret), then revert the commit from step 8, which brings back `.env.tpl` and
`make palworld-secret`, and run that target. Nothing else depends on ESO yet.

## Notes

- **The token expires.** Put a reminder in a calendar for a week before. To
  renew: create a new token on the same service account (or a new account),
  update the `eso-service-account` item, run `make eso-token`. Existing Secrets
  keep working in the meantime; only new syncs fail.
- **If 1Password is unreachable,** Secrets that already exist stay in place.
  Only creating or changing them stops.
- **Rate limits.** A one-hour refresh across a handful of ExternalSecrets is far
  below the service account limits. Don't shorten it to seconds. The provider
  also has an optional client-side cache (default TTL 5 minutes); the docs call
  it experimental, so leave it off unless limits become a problem.
- **Unique field names.** The 1Password SDK provider needs the fields in an item
  to have unique labels. Two fields with the same label in one item is an error.
- **Secrets are still ordinary Kubernetes Secrets,** so they sit unencrypted in
  k3s's datastore. k3s can encrypt them at rest (`secrets-encryption: true` in
  the server config) if that matters; it's a separate decision.
- A rebuilt cluster (`make rebuild`) needs `make eso-token` to run, which `up`
  does for you. After that every Secret comes back by itself.
- The repo is public, and the manifests name the vault and item. That reveals
  the layout, not any value.

## After phase 3

1. Reloader (or similar) so pods restart when a Secret changes.
2. Off-host backups of the Palworld volume.
3. Each new personal project adds its own `ExternalSecret`, with items in
   `homelab-k8s`.
