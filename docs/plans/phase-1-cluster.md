# Phase 1: k3s cluster on Proxmox

Goal: a three-node k3s cluster on the Proxmox homelab, created with OpenTofu
and configured with Ansible. "Done" means the whole cluster can be destroyed
and rebuilt from this repo with no manual steps.

## Decisions

| Topic | Decision | Why |
| --- | --- | --- |
| Distribution | k3s on Ubuntu 24.04 VMs | Light enough for 32GB; works with Ansible (Talos would replace Ansible) |
| Topology | 1 server + 2 agents | Shows scheduling, taints and draining; 3 servers would cost ~6GB for HA that one host can't provide |
| Provisioning | OpenTofu + `bpg/proxmox` provider | Well maintained; supports cloud images and cloud-init |
| State | AWS S3 (versioned, native lockfile locking), encrypted client-side with OpenTofu state encryption | Work happens from both the WSL desktop and a MacBook; S3 is the backend's native target, and versioning allows rolling back a bad state write |
| Secrets | 1Password, injected with `op run` | No secrets in the repo, encrypted or otherwise |
| Load balancing | MetalLB in L2 mode (k3s `servicelb` disabled) | Game servers need UDP/TCP Services with fixed LAN IPs |
| VM disks | qcow2 files on the existing ext4 directory storages | Already set up; matches VM 200; qcow2 supports snapshots. LVM-thin would mean wiping the NVMe for a small speed gain |
| Storage | k3s local-path provisioner on a SATA SSD data disk | Simple; Longhorn's replication protects nothing on one physical disk |
| Friend access | Existing WireGuard on the router (unchanged) | Peers limited to the DNS server and the Palworld IP, enforced by the firewall |

## Proxmox host (measured 2026-10-12)

- Proxmox VE 9.2.2, kernel 7.0. No ZFS anywhere, so no ARC to cap.
- 31GiB usable RAM, 8GB swap on the boot SSD.
- Proxmox itself uses about 1.6GB. VM 200's process was at 7.8GB with an idle
  server (Palworld itself at 1.1GB); it can grow to its full 20GB under load.

| Storage | Type | Disk | Content enabled | Used for |
| --- | --- | --- | --- | --- |
| `local` | dir | boot SSD | import, iso, vztmpl, backup | Ubuntu cloud image |
| `local-lvm` | lvmthin | boot SSD | images, rootdir | Unused (337GB free) |
| `nvme-ssd-1tb` | dir (ext4) | NVMe | images, snippets, iso, ... | k3s node boot disks, cloud-init snippets |
| `sata-ssd-1tb` | dir (ext4) | SATA SSD | images, snippets, iso, ... | VM 200, worker data disks |
| `hdd-2tb` | dir (ext4) | HDD | images, snippets, backup, ... | Backups |

## Memory budget

VM 200 (the old Palworld server, 20GB) is shut down for the rest of the
migration (step 3), so the nodes are built at their final sizes from the start.

| VM | vCPU | RAM | Runs |
| --- | --- | --- | --- |
| k3s-cp-1 | 2 | 3GB | Control plane (tainted) |
| k3s-worker-1 | 8 | 16GB | Palworld |
| k3s-worker-2 | 4 | 8GB | Minecraft, Argo CD, MetalLB, monitoring |
| VM 200 | 6 | 0 (shut down, 20GB if started) | Old Palworld server, kept as a rollback |

This leaves about 4GB for the Proxmox host. Ballooning is off on all nodes
because the kubelet reads node memory once at startup.

Don't start VM 200 while the cluster is running at these sizes: 20GB on top of
27GB of nodes overcommits the host. To roll back, stop the cluster VMs first.

## Network plan

| Name | IP |
| --- | --- |
| Router / AdGuard DNS | 192.168.8.1 |
| Proxmox host (static) | 192.168.8.150 |
| VM 200, Palworld (DHCP, shut down) | 192.168.8.119 |
| k3s-cp-1 | 192.168.8.11 |
| k3s-worker-1 | 192.168.8.12 |
| k3s-worker-2 | 192.168.8.13 |
| MetalLB `games` pool | 192.168.8.48/29 (.48 - .55) |
| MetalLB `general` pool | 192.168.8.56/29 (.56 - .63) |

The k3s nodes and MetalLB pools must sit outside the router's DHCP pool (the
GL.iNet default is .100 - .249). The Proxmox host and VM 200 sit inside it, so
both need DHCP reservations to keep the router from handing their addresses
to another device.

### Game server addresses

Game servers get a dedicated CIDR-aligned block, so friend access is one
firewall rule and one `AllowedIPs` entry no matter how many games run.

| Address | Service |
| --- | --- |
| 192.168.8.48 | Palworld (UDP 8211) |
| 192.168.8.49 | Minecraft (TCP 25565) |
| 192.168.8.50 - .55 | Free for future games |

- The `games` pool sets `autoAssign: false`, so Services that don't ask for it
  (Traefik, test Services) never get a game IP. Each game Service pins its
  address with the `metallb.io/loadBalancerIPs` annotation.
- Friends' `AllowedIPs`: `192.168.8.1/32, 192.168.8.48/29`. The router
  firewall allows the same block, limited to the game ports.
- This is a block of addresses in the existing /24, not a VLAN. A VLAN for the
  load-balancer IPs alone adds little isolation, because the nodes behind them
  sit on the main LAN anyway. Real segmentation means moving the whole cluster
  into its own VLAN, which is a separate project.

---

## Step 0: Tidy up the repo

1. Sync `apps/palworld/compose.yaml` with the copy running on VM 200 (WireGuard,
   no `PUBLIC_IP`, 19GB limit, Global Palbox settings) and drop the `playit`
   service and `PLAYIT_SECRET_KEY`.
2. Update both READMEs for WireGuard.
3. Remove `.terraform.lock.hcl` from `.gitignore` so the provider lock file is
   committed.
4. Move the plan and checklist into `docs/plans/`. Add `.editorconfig` and
   `.gitattributes` (LF line endings between Windows and WSL).
5. Commit.

## Step 1: Install tools in WSL

```bash
# OpenTofu
curl -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh
chmod +x /tmp/install-opentofu.sh && /tmp/install-opentofu.sh --install-method deb

# Ansible (pipx keeps it out of the conda Python)
sudo apt install -y pipx && pipx ensurepath
pipx install --include-deps ansible
pipx install ansible-lint

# kubectl and Helm: use the install steps from their official docs
```

Check: `tofu version`, `ansible --version`, `kubectl version --client` and
`helm version` all work.

## Step 1 Alt: Install tools on MacOS

`brew install opentofu ansible kubectl helm 1password-cli`

## Step 2: Check the Proxmox host

```bash
ssh root@homelab.internal 'pveversion; pvesm status; free -h; qm list; lsblk'
```

Done. The results are recorded in "Proxmox host" above: Proxmox VE 9, no ZFS,
and every data disk is already an ext4 directory storage with `images` and
`snippets` enabled.

## Step 3: Prepare Proxmox (one time)

1. Storage: no changes needed. Node boot disks and cloud-init snippets go on
   `nvme-ssd-1tb`, worker data disks on `sata-ssd-1tb`, and the cloud image on
   `local` (which already allows `import`).
2. Shut down VM 200 for the rest of the migration, keeping the world safe
   first:

   ```bash
   # Stop the container cleanly so the world is flushed to disk
   ssh palworld 'cd ~/palworld && docker compose down'

   # Copy the save off the VM, outside the repo
   rsync -a palworld:~/palworld/palworld/Pal/Saved/ ~/backups/palworld-2026-10-14/

   # Shut down, stop it auto-starting, and take a full backup to the HDD
   ssh root@homelab.internal 'qm shutdown 200 && qm set 200 --onboot 0 && vzdump 200 --storage hdd-2tb --mode stop --compress zstd'
   ```

   `--onboot 0` keeps a host reboot from starting VM 200 on top of the
   cluster (see "Memory budget").
3. Create an API user and token for OpenTofu:

   ```bash
   pveum user add tofu@pve --comment "OpenTofu"
   pveum role add TofuProvisioner --privs "<privilege list from the bpg/proxmox docs for PVE 9>"
   pveum acl modify / --users tofu@pve --roles TofuProvisioner
   pveum user token add tofu@pve provider --privsep 0
   ```

   Save the token ID and secret in 1Password, for example as
   `op://homelab/proxmox-tofu/token`.
4. SSH for the provider: it uses SSH to upload snippets. Root SSH to
   `homelab.internal` with `~/.ssh/id_ed25519` works. Make sure `ssh-agent` is
   running in WSL with that key loaded.

## Step 4: Network

1. Check the router's DHCP pool range.
2. Add DHCP reservations for the Proxmox host (`192.168.8.150`) and VM 200
   (`192.168.8.119`, MAC `BC:24:11:F2:BB:4E`) if they aren't there already.
   VM 200's address matters until it's deleted, since a rollback depends on it.
3. Ping each planned IP to make sure nothing already uses it.
4. Add AdGuard rewrites: `k3s-cp-1.internal`, `k3s-worker-1.internal` and
   `k3s-worker-2.internal`.
5. No firewall change needed. Friends' WireGuard rules already block the new
   nodes.

## Step 5: Secrets and the state bucket

### Secrets in 1Password

| Item | How to make it |
| --- | --- |
| Proxmox API token | Step 3 |
| State encryption passphrase | Long random string. If it's lost, the state can't be read. |
| AWS access key for the state user | Created by hand after the bootstrap below |
| k3s join token | `openssl rand -hex 32` |

Add `.env.tpl` files with `op://` references in `tofu/homelab/` and `ansible/`.
Run commands as `op run --env-file=.env.tpl -- <command>` so values never touch
disk.

### Bootstrap the S3 state bucket

A small separate stack in `tofu/bootstrap/` creates what the main stack's
backend depends on. Run it once with your own AWS admin credentials (for
example an `aws sso login` profile), not the state user's key.

- Bucket `austianosc-homelab-tofu-state` in `us-west-2`:
  - Versioning on, so a bad state write can be rolled back.
  - All public access blocked, and SSE-S3 default encryption.
  - A lifecycle rule that expires noncurrent versions after 90 days.
- IAM user `homelab-tofu-state` with a policy scoped to this bucket only:
  - `s3:ListBucket` on the bucket.
  - `s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` on objects in it
    (the delete is needed to release `.tflock` lock files).
- No access key in OpenTofu. A key created by OpenTofu would be stored in
  state, so create it by hand
  (`aws iam create-access-key --user-name homelab-tofu-state`) and save it
  straight into 1Password.

The bootstrap stack starts with local state. Once the bucket exists, add a
backend block pointing at `bootstrap/terraform.tfstate` in the same bucket and
run `tofu init -migrate-state`, so nothing lives only on one laptop.

Check: `aws s3api get-bucket-versioning --bucket austianosc-homelab-tofu-state`
reports `Enabled`.

## Step 6: Create the VMs with OpenTofu

The code lives in `infra/` (S3 bucket `lab-terratofu-state`, key
`infra/terraform.tfstate`, authenticated through the `austin-sandbox` AWS SSO
profile rather than a long-lived IAM key). It is written and validates; the
`plan` and `apply` below are the remaining steps.

| File | What it does |
| --- | --- |
| `backend.tf`, `encryption.tf` | S3 backend with native locking; client-side `aes_gcm` encryption, `enforced` for state and plans |
| `providers.tf` | `bpg/proxmox` `~> 0.116` against `https://homelab.internal:8006/` (self-signed cert, so `insecure`); API token from `PROXMOX_VE_API_TOKEN`, SSH as root through the agent |
| `image.tf` | Ubuntu 24.04 cloud image pinned to the 20260926 release and its SHA256, imported into `local` |
| `nodes.tf` | The `local.nodes` map (single source of truth) and one `module.node` per entry |
| `access.tf` | Admin user and the SSH public keys cloud-init authorizes |
| `modules/proxmox-vm/` | One VM: `host` CPU, ballooning off, qcow2 boot disk on `nvme-ssd-1tb`, optional data disk on `sata-ssd-1tb` mounted at `/var/lib/rancher/k3s/storage`, static IP via cloud-init, guest agent, `on_boot` |
| `inventory.tf` | Renders `ansible/inventory/hosts.yml` from `local.nodes`; the file is committed |
| `.terraform.lock.hcl` | Committed, with checksums for `linux_amd64` and `darwin_arm64` |

Before the first plan:

1. Finish step 3, and save the API token as the full string
   `tofu@pve!provider=<secret>` at `op://homelab/proxmox-tofu/token` (the path
   in `infra/.env.tpl`).
2. Load the SSH key into the agent (`ssh-add ~/.ssh/id_ed25519`) and confirm
   `ssh root@homelab.internal` works.
3. To work from the MacBook, add its public key to `local.ssh_public_keys` in
   `infra/access.tf` and apply, so both machines render identical cloud-init.

Run:

```bash
cd infra
aws sso login --profile austin-sandbox
op run --env-file=.env.tpl -- tofu init
op run --env-file=.env.tpl -- tofu plan    # expect 3 VMs, 3 snippets, 1 image, 1 inventory file
op run --env-file=.env.tpl -- tofu apply
```

The first apply also destroys the `terraform_data.state_smoke_test` left over
from the backend test; that's expected.

Check:

- `ssh austin@<node-ip>` works on all three nodes.
- The Proxmox UI shows each VM's IP from the guest agent.
- `ssh austin@192.168.8.12 'findmnt /var/lib/rancher/k3s/storage'` shows the
  data disk on both workers.
- `aws s3 cp s3://lab-terratofu-state/infra/terraform.tfstate - | head -c 200`
  shows an encrypted payload, not readable resource data.
- No `terraform.tfstate` file exists locally.
- `tofu plan` from the other machine (WSL or the Mac) reports no changes.

## Step 7: Install k3s with Ansible

The code is in `ansible/`; it passes `--syntax-check` and `ansible-lint` with
the `production` profile, and all three nodes are reachable with sudo.

| File | What it does |
| --- | --- |
| `ansible.cfg` | Uses the generated inventory, `StrictHostKeyChecking=accept-new`, pipelining |
| `inventory/hosts.yml` | Generated by OpenTofu (step 6); don't edit |
| `inventory/group_vars/all.yml` | `k3s_version: v1.36.5+k3s1` (stable channel), timezone, server URL, `k3s_token` from the `K3S_TOKEN` env var, kubeconfig path |
| `roles/base` | Dist-upgrade, timezone, unattended security upgrades without auto-reboot, inotify limits, journald capped at 500M, swap-off check, reboot if an upgrade requires it (`base_reboot_if_required`) |
| `roles/k3s_server` | Writes `/etc/rancher/k3s/config.yaml` (token, node IP, embedded etcd, `tls-san`, control-plane taint, `servicelb` disabled), runs the install script pinned to the same tag, waits for the node to be Ready |
| `roles/k3s_agent` | Same, joining `https://192.168.8.11:6443`; the server confirms the node is Ready |
| `playbooks/site.yml` | Preflight token check, then `base` on all nodes, server, agents, and finally writes `~/.kube/homelab.yaml` pointing at the control plane with the context renamed `homelab` |
| `requirements.yml` | `ansible.posix` and `community.general` (bundled with the full `ansible` package) |
| `.env.tpl` | `K3S_TOKEN=op://homelab/k3s/password` |

Upgrading k3s later is changing `k3s_version` and re-running the playbook: the
server upgrades first, then the agents.

Before the first run, create the join token in 1Password. It is baked into the
cluster at install time, so it can't simply be changed later:

```bash
op item create --vault homelab --category password --title k3s \
  --generate-password='64,letters,digits'
```

Run:

```bash
cd ansible
op run --env-file=.env.tpl -- ansible-playbook playbooks/site.yml
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get nodes -o wide
```

Check:

- All three nodes show `Ready`.
- `kubectl get pods -A` shows CoreDNS, Traefik, metrics-server and the
  local-path provisioner running.
- Running the playbook a second time reports zero changes. (The first run may
  reboot nodes after the dist-upgrade; that's expected.)
- After a rebuild in step 9, clear the old host keys first:
  `for ip in 11 12 13; do ssh-keygen -R 192.168.8.$ip; done`.

## Step 8: MetalLB and storage test

Done. The manifests are in `kubernetes/infra/metallb/` (chart `0.16.1`, with
its own README), and all of the tests below passed.

1. Install MetalLB with Helm, pinned and with values from the repo. `values.yaml`
   turns off the chart's `frrk8s` BGP backend, which is on by default and costs
   about 190MB and constant CPU for a mode L2 doesn't use:

   ```bash
   helm repo add metallb https://metallb.github.io/metallb
   helm upgrade --install metallb metallb/metallb --version 0.16.1 \
     -n metallb-system --create-namespace \
     -f kubernetes/infra/metallb/values.yaml --wait
   ```

2. Apply two `IPAddressPool`s and an `L2Advertisement` covering both, from
   `kubernetes/infra/metallb/`, so Argo CD can take them over later:
   - `games`: `192.168.8.48/29`, `autoAssign: false`.
   - `general`: `192.168.8.56/29`.

   `autoAssign: false` only stops *automatic* assignment: an unannotated
   Service never lands in `games`, but one that names the pool or an address in
   it can still take it. Nothing in the cluster enforces more than convention
   here, so game Services should always pin their address.
3. Load balancer tests:
   - Deploy nginx with a plain `LoadBalancer` Service. It should get an IP
     from `general`, and `curl` should work from your PC. Traefik also takes a
     `general` IP; that's expected.
   - Add the annotation `metallb.io/loadBalancerIPs: 192.168.8.50` and check
     the Service moves to that address, which proves pinning from the `games`
     pool works.
4. Storage test: create a PVC and a pod pinned to `k3s-worker-1` that writes
   a file. Check the file shows up under `/var/lib/rancher/k3s/storage`.
5. Delete the test resources.

## Step 9: Rebuild from scratch

Destroy the whole cluster and rebuild it from the repo alone. Phase 1 is done
when this produces a working cluster with no manual fixes. These steps assume
the MacBook; on WSL they're the same minus the Mac-specific setup.

What gets destroyed: the three k3s VMs, their disks (including the data disks),
the cloud-init snippets, the Ubuntu image and the generated inventory file.
Nothing on the cluster needs keeping yet. VM 200 isn't in OpenTofu's state, so
it's untouched.

### 1. Check the Mac is ready

```bash
cd ~/path/to/homelab-infra && git pull

# Tools (once): Homebrew's ansible includes ansible.posix and community.general
brew install opentofu ansible kubectl helm 1password-cli awscli

# On the home network or WireGuard: names must resolve and SSH must work
dig +short k3s-cp-1.internal          # 192.168.8.11
ssh root@homelab.internal true        # the provider uploads snippets as root
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
ssh-add -l                            # the key must be loaded in the agent

# 1Password CLI signed in (desktop app integration)
op whoami

# AWS SSO for the state bucket. ~/.aws/config must define the austin-sandbox
# profile; copy it from WSL (~/.aws/config.tpl, rendered with op inject).
export AWS_PROFILE=austin-sandbox
aws sso login
```

The root SSH check matters: the Mac's key must be in root's
`~/.ssh/authorized_keys` on the Proxmox host, not just in
`infra/access.tf` (that one only covers the nodes). `tofu plan` works without
it because plans only use the API, but `apply` and `destroy` upload and remove
the cloud-init snippets over SSH. As of 2026-10-19 the Mac's key is not there;
add it once from WSL (`/root/.ssh/authorized_keys` is a symlink to Proxmox's
`/etc/pve/priv/authorized_keys`, so appending through it is correct):

```bash
ssh root@homelab.internal \
  'echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOEWAC14hfDesqPfXEbAeWnlQswxy7Vz/D5eCORuBQZe m2-macbook" >> /root/.ssh/authorized_keys'
```

### 2. Confirm OpenTofu sees the current cluster

```bash
cd infra
op run --env-file=.env.tpl -- tofu init
op run --env-file=.env.tpl -- tofu plan     # expect: No changes
```

If this plan isn't clean, stop and find out why before destroying anything.

### 3. Destroy

```bash
date                                         # start time, for the README
op run --env-file=.env.tpl -- tofu destroy
```

Expect 8 resources destroyed: 3 VMs, 3 snippets, the image and the inventory
file. `ssh root@homelab.internal qm list` should then show only VM 200.
`git status` shows `ansible/inventory/hosts.yml` deleted until the next apply
regenerates it.

### 4. Recreate the VMs

```bash
op run --env-file=.env.tpl -- tofu apply
```

This downloads the image again and waits for each guest agent, so a few
minutes is normal. Afterwards `git status` should be clean again: the
regenerated inventory is identical to the committed one.

### 5. Forget the old host keys

The new VMs have new SSH host keys, and Ansible refuses keys that change:

```bash
for h in 192.168.8.11 192.168.8.12 192.168.8.13 \
         k3s-cp-1.internal k3s-worker-1.internal k3s-worker-2.internal; do
  ssh-keygen -R "$h"
done
```

### 6. Install k3s

```bash
cd ../ansible
op run --env-file=.env.tpl -- ansible-playbook playbooks/site.yml
```

The first run may reboot nodes after the upgrade. It ends by writing a fresh
`~/.kube/homelab.yaml` on the Mac.

### 7. Reinstall MetalLB

```bash
cd ..
export KUBECONFIG=~/.kube/homelab.yaml
helm repo add metallb https://metallb.github.io/metallb
helm upgrade --install metallb metallb/metallb --version 0.16.1 \
  -n metallb-system --create-namespace \
  -f kubernetes/infra/metallb/values.yaml --wait
kubectl apply -f kubernetes/infra/metallb/pools.yaml
date                                         # end time
```

### 8. Verify

| Check | Command | Expected |
| --- | --- | --- |
| Nodes | `kubectl get nodes` | All three `Ready`, `v1.36.5+k3s1` |
| System pods | `kubectl get pods -A` | All `Running` or `Completed` |
| MetalLB | `kubectl get svc -n kube-system traefik` | `EXTERNAL-IP 192.168.8.56` |
| Load balancing | `curl -s -o /dev/null -w '%{http_code}\n' http://192.168.8.56/` | `404` (Traefik answering, no routes yet) |
| Data disks | `ssh austin@192.168.8.12 findmnt /var/lib/rancher/k3s/storage` | Mounted from `/dev/sdb` (same on `.13`) |
| Ansible is idempotent | Run the step 6 command again | `changed=0` on every host |
| OpenTofu is idempotent | `cd infra && op run --env-file=.env.tpl -- tofu plan` | `No changes` |

### 9. Bring WSL up to date

The WSL desktop still has the old cluster's host keys and kubeconfig. From WSL:

```bash
for h in 192.168.8.11 192.168.8.12 192.168.8.13 \
         k3s-cp-1.internal k3s-worker-1.internal k3s-worker-2.internal; do
  ssh-keygen -R "$h"
done
cd ~/projects/homelab-infra/ansible
op run --env-file=.env.tpl -- ansible-playbook playbooks/site.yml   # changed=0, refreshes the kubeconfig
```

### Record the result

Note the start and end times for the README's "rebuild from zero" section. The
host key cleanup (step 5) and the MetalLB install (step 7) are the two manual
pieces left; a Makefile target and Argo CD (step 10 and after) remove them.

## Step 10: Docs and CI

- Makefile targets: `plan`, `apply`, `cluster`, `kubeconfig`, `destroy`.
- `.github/workflows/lint.yml`: `tofu fmt -check`, `tofu validate`, `tflint`
  and `ansible-lint` on pull requests. Lint only; CI never runs `apply`.
- `docs/adr/`: k3s over Talos, one control plane, encrypted state in S3 (over
  R2 and local state), MetalLB over servicelb, local-path over Longhorn.
- README: tick off roadmap items, add an architecture diagram, and add a
  "rebuild from zero" section.

---

## After phase 1

1. Argo CD, then hand MetalLB over to it.
2. Minecraft (`itzg/minecraft-server`, ~4GB heap, 5-6GB pod) as the first real
   workload, pinned to `192.168.8.49`. This is when friend access moves to the
   game block: add `192.168.8.48/29` to the router firewall rule (UDP 8211,
   TCP 25565) and to each friend's `AllowedIPs`, alongside `192.168.8.119`.
   This is the last change to friends' configs; later games are covered.
3. Palworld cutover (VM 200 is already shut down, with the save copied off in
   step 3):
   - `rsync` the saved `Pal/Saved/` directory into the new PVC. Don't bring
     `WorldOption.sav` along.
   - Run a StatefulSet with the same image and environment variables. The
     Service is pinned to `192.168.8.48` with the `metallb.io/loadBalancerIPs`
     annotation and uses `externalTrafficPolicy: Local`. Leave `PUBLIC_IP`
     unset, as on the VM; set it to `192.168.8.48` only if clients fail to
     connect.
   - Point `palworld.internal` at `192.168.8.48` in AdGuard.
   - Delete VM 200 and its backup once the server has run on the cluster for
     a week. Then remove `192.168.8.119` from the firewall rule and friends'
     `AllowedIPs` (leaving it there is harmless if a friend doesn't update).
4. Later: codify the router's WireGuard peers and firewall rules with Ansible.