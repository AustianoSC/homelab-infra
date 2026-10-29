# Phase 2: GitOps with Argo CD, and Palworld on the cluster

Goal: pushing to `main` changes the cluster, and the Palworld server runs on it
instead of on VM 200. "Done" means friends play on the cluster, the VM is gone,
and nothing was deployed by hand except Argo CD itself.

## Decisions

| Topic | Decision | Why |
| --- | --- | --- |
| Deployment | Argo CD pulls from this repo; "app of apps" | See [ADR 0007](../adr/0007-pull-based-gitops.md). Adding a workload is adding a file |
| Repo access | The repo is public, so Argo CD pulls it over HTTPS with no credentials | Nothing to store or rotate, and nothing for Argo CD to leak. A deploy key would only protect a private repo |
| MetalLB | Argo CD adopts the running release: same chart, same values | `helm template` renders exactly the 25 resources Helm installed, so adopting changes nothing |
| Secrets | Created from 1Password by `make`, never in Git | External Secrets replaces this in [phase 3](phase-3-external-secrets.md), once Palworld is stable |
| Argo CD UI | `https://192.168.8.57`, self-signed, in the `general` pool | Friends can't reach it: their access is the `games` block only |
| Palworld | One-pod StatefulSet pinned to `k3s-worker-1`, image pinned to `v2.8.0` | Same image the VM runs today (`latest` is the same digest), so the migration doesn't also change the server version |
| Palworld volume | A 40GiB claim that Argo CD never prunes | The `local-path` class deletes data with the claim and can't grow |
| Memory | Request 10Gi, limit 14Gi | The node has about 15.6GiB; the MetalLB speaker has to fit beside it |

## What's in the repo

| Path | What it is |
| --- | --- |
| `kubernetes/argocd/values.yaml` | Argo CD chart values (no Dex, notifications or ApplicationSet; UI on `.57`) |
| `kubernetes/argocd/root-app.yaml` | The one Application applied by hand; it creates the others |
| `kubernetes/argocd/applications/` | One Application per workload: `metallb`, `metallb-pools`, `palworld` |
| `kubernetes/apps/palworld/` | The StatefulSet, Service (`192.168.8.48`) and volume claim, plus `.env.tpl` |
| `Makefile` | `make argocd` and `make palworld-secret`; `make up` runs them |

## Part 1: Argo CD

- [x] **1. Make the repo public.** Argo CD can only pull without credentials
  from a public repo, so do this first: GitHub, repo Settings, General, Danger
  Zone, Change visibility. Making a repo public exposes its whole history, not
  just the current files. The history was scanned on 2026-10-23 (`gitleaks`: no
  leaks in all 27 commits; no committed `.env`, keys or tokens), but run it
  again right before the switch. This needs the `gitleaks` command itself
  (`brew install gitleaks`; on Linux, download the binary from the project's
  [releases page](https://github.com/gitleaks/gitleaks/releases)). The
  pre-commit hook builds its own copy, so it doesn't put one on your `PATH`:
  ```bash
  gitleaks git --redact .
  ```
  Afterwards, turn on Settings, Code security, **Secret scanning** and **Push
  protection**, which are free for public repos and block a secret from being
  pushed by accident.

- [x] **2. Create the Palworld Secret.** (As written for phase 2: `make
  palworld-secret` was removed in phase 3, where External Secrets creates the
  Secret instead.) The namespace and Secret have to exist
  before the first start; `make up` does this, or on its own:
  ```bash
  make palworld-secret
  ```

- [x] **3. Install Argo CD.** First **commit and push** everything under
  `kubernetes/` to `main`. Argo CD reads GitHub, not your working copy, so
  until the files are pushed the `root` Application shows `Unknown` with "app
  path does not exist" and deploys nothing. Check with
  `git ls-tree -r --name-only origin/main | grep kubernetes/argocd`. Then:
  ```bash
  make argocd
  ```
  This installs the chart, waits for the repo server and controller, and
  applies `root-app.yaml`. Argo CD then creates the three
  Applications and syncs them.
  It stays in `Progressing` for a minute or two, because Argo CD's own Service
  can't get `192.168.8.57` until it has synced MetalLB.

- [ ] **4. Hand MetalLB over.** Argo CD now manages the existing release, but
  Helm still holds its own record of it. Remove only that record, so there is a
  single owner:
  ```bash
  kubectl -n metallb-system delete secret -l owner=helm,name=metallb
  ```
  This deletes Helm's bookkeeping Secret, not MetalLB. Wait until the `metallb`
  Application is `Synced` and `Healthy` first.

- [ ] **5. Check it.**
  | Check | Command | Expected |
  | --- | --- | --- |
  | Applications | `kubectl -n argocd get applications` | `root`, `metallb`, `metallb-pools` Synced and Healthy. `palworld` is Synced but Progressing: its volume waits for a pod, which is expected until part 2 |
  | Addresses | `kubectl get svc -A` | Traefik `192.168.8.56`, `argocd-server` `192.168.8.57`, Palworld `192.168.8.48` |
  | One owner | `helm list -A` | No `metallb` release (Traefik's are k3s's own) |
  | Self-heal | `kubectl -n metallb-system scale deploy metallb-controller --replicas=0` | Back to 1 replica within a minute or so, put there by Argo CD |

- [x] **6. Log in.** The initial password is generated, so read it, change it in
  the UI, then delete the Secret:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  ```
  Open `https://192.168.8.57` (accept the certificate warning), user `admin`.
  After changing the password: `kubectl -n argocd delete secret argocd-initial-admin-secret`.
  Optionally add an AdGuard rewrite `argocd.internal` to `192.168.8.57`.

Argo CD polls Git about every three minutes; the Refresh button in the UI or
`kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=normal`
skips the wait.

## Part 2: Palworld cutover

Before starting: VM 200 is shut down, the save from it is at
`~/backups/palworld-2026-10-14` on the WSL desktop (taken with the server
stopped, and the VM hasn't run since), and part 1 is done.

- [x] **7. Restore the save into the volume.** The Application is deployed with
  zero replicas, because a server started on an empty volume installs itself and
  creates a new world. Load the old one first, through a throwaway pod pinned to
  the same node:
  ```bash
  kubectl -n palworld apply -f - <<'EOF'
  apiVersion: v1
  kind: Pod
  metadata:
    name: palworld-restore
  spec:
    restartPolicy: Never
    nodeSelector:
      kubernetes.io/hostname: k3s-worker-1
    containers:
      - name: restore
        image: busybox:1.37
        command: ["sleep", "3600"]
        volumeMounts:
          - { name: data, mountPath: /palworld }
    volumes:
      - name: data
        persistentVolumeClaim:
          claimName: palworld-data
  EOF
  kubectl -n palworld wait --for=condition=Ready pod/palworld-restore --timeout=120s

  tar -C ~/backups/palworld-2026-10-14 --exclude=WorldOption.sav -cf - . \
    | kubectl -n palworld exec -i palworld-restore -- \
        sh -c 'mkdir -p /palworld/Pal/Saved && tar -C /palworld/Pal/Saved -xf - && chown -R 1000:1000 /palworld'

  kubectl -n palworld exec palworld-restore -- find /palworld/Pal/Saved -maxdepth 4 -name '*.sav' -o -name '*.ini'
  kubectl -n palworld delete pod palworld-restore
  ```
  Everything under `Saved/` is restored, because `GameUserSettings.ini` there is
  what tells the server which world to load. `WorldOption.sav` is left out on
  purpose: while it exists it overrides all the environment variables. Check
  that the listing shows `SaveGames/0/<world>/Level.sav` and `Players/`.

- [x] **8. Start the server.** Set `replicas: 1` in
  `kubernetes/apps/palworld/statefulset.yaml`, commit and push to `main`. Then:
  ```bash
  kubectl -n palworld logs -f palworld-0
  ```
  The first start downloads the server with SteamCMD, so allow several minutes.
  Then check:
  | Check | Command | Expected |
  | --- | --- | --- |
  | Placement | `kubectl -n palworld get pod -o wide` | Running on `k3s-worker-1` |
  | Address | `kubectl -n palworld get svc palworld` | `EXTERNAL-IP 192.168.8.48` |
  | Memory | `kubectl top pod -n palworld` | Well under the 14Gi limit |

- [x] **9. Open the network path** (on the router; this repo doesn't manage it):
  - AdGuard: point `palworld.internal` at `192.168.8.48` instead of `.119`.
  - Firewall: allow the WireGuard peers to `192.168.8.48/29`, on the same ports
  as the existing rule for `.119` (UDP 8211 is the one that matters).
  - Friends' WireGuard configs: add `192.168.8.48/29` to `AllowedIPs`, **next
  to** `192.168.8.119` so a rollback still works. This is the last change to
  their configs: later games land in the same block.

- [ ] **10. Test it yourself first.** Over WireGuard, connect to
  `palworld.internal:8211` with the server password. Check that your character,
  pals and base are there, then ask a friend to join.

- [ ] **11. Burn in for a week.** Watch `kubectl top pod -n palworld` for
  memory and `kubectl -n palworld get pod` for restarts. The nightly 05:00
  reboot makes the container exit, and Kubernetes restarts it, so the restart
  count goes up by one a night (6 after 6 days) and the last restart should be
  about 05:00. More than that, or a restart at another time, means a crash or
  an out-of-memory kill: check
  `kubectl -n palworld describe pod palworld-0 | grep -A5 'Last State'`.
  `kubectl logs` shows only the current container; `kubectl logs -p` shows the
  one before it, which is the one that ran through the 03:00 backup and 04:00
  update check.

- [ ] **12. Retire the VM.** Only after a week of stable play:
  ```bash
  # A fresh copy of the live world, from the cluster
  mkdir -p ~/backups/palworld-cluster-$(date +%F)
  kubectl -n palworld exec palworld-0 -- tar -C /palworld/Pal -cf - Saved \
    | tar -C ~/backups/palworld-cluster-$(date +%F) -xf -

  # On the Proxmox host
  ssh root@homelab.internal 'qm destroy 200 --purge'
  ```
  Delete the `vzdump` backup of VM 200 from `hdd-2tb` (Proxmox UI, `hdd-2tb`,
  Backups). Remove `192.168.8.119` from the firewall rule and friends'
  `AllowedIPs` (leaving it in is harmless if a friend doesn't update), and its
  DHCP reservation. In the repo, remove `apps/palworld/compose.yaml` and
  `apps/palworld/.env.tpl`, and update `apps/palworld/README.md`, whose
  save-migration notes are still worth keeping.

## Rolling back

Until step 12, the VM is the fallback. Copy the live world off the cluster first
(the command in step 12), so progress since the cutover isn't lost. Then stop
the cluster VMs, because the VM's 20GB on top of the nodes' 27GB overcommits the
host, start VM 200, and put the AdGuard rewrite back on `192.168.8.119`.
Friends' `AllowedIPs` still include that address.

## Notes

- A rebuilt cluster (`make rebuild`) comes back with Palworld running and
an **empty** world, because the data disks are recreated. Back up the world
before destroying anything.
- The world lives on one SSD plus the server's own nightly backups on the same
volume. Off-host backups are the first thing to add afterwards.

## After phase 2

1. Off-host backups of the Palworld volume.
2. Argo CD Image Updater and deploy flows for personal projects (pull model, no

   runners on public repos; see ADR 0007).
3. External Secrets with 1Password, replacing `make palworld-secret`: see

   [phase 3](phase-3-external-secrets.md).
4. Observability (VictoriaMetrics + Grafana).
5. Codify the router's WireGuard peers and firewall rules with Ansible.
