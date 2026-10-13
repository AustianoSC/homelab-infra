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
| State | Local, encrypted with OpenTofu state encryption | Single operator; move to a remote backend when CI runs `tofu` |
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

VM 200 (the current Palworld server) keeps running during phase 1, so the
nodes start small and grow after the Palworld cutover. VM 200 is currently
20GB, which together with the nodes would leave the host nothing at peak, so
step 3 shrinks it to 16GB first.

| VM | vCPU | RAM in phase 1 | RAM after cutover | Runs |
| --- | --- | --- | --- | --- |
| k3s-cp-1 | 2 | 3GB | 3GB | Control plane (tainted) |
| k3s-worker-1 | 8 | 4GB | 16GB | Palworld |
| k3s-worker-2 | 4 | 4GB | 8GB | Minecraft, Argo CD, MetalLB, monitoring |
| VM 200 | 6 | 16GB (now 20GB) | deleted | Current Palworld server |

This leaves about 4GB for the Proxmox host in both stages. Ballooning is off on
all nodes because the kubelet reads node memory once at startup.

## Network plan

| Name | IP |
| --- | --- |
| Router / AdGuard DNS | 192.168.8.1 |
| Proxmox host (static) | 192.168.8.150 |
| VM 200, Palworld (DHCP) | 192.168.8.119 |
| k3s-cp-1 | 192.168.8.11 |
| k3s-worker-1 | 192.168.8.12 |
| k3s-worker-2 | 192.168.8.13 |
| MetalLB pool | 192.168.8.50 - 192.168.8.59 |

The k3s nodes and MetalLB pool must sit outside the router's DHCP pool (the
GL.iNet default is .100 - .249). The Proxmox host and VM 200 sit inside it, so
both need DHCP reservations to keep the router from handing their addresses
to another device.

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
2. Shrink VM 200 from 20GB to 16GB so the nodes fit (see "Memory budget").
   Do it when nobody is playing, since the server restarts:
   1. Set `mem_limit: 15g` in `apps/palworld/compose.yaml` and update the
      "20GB VM" comments to 16GB.
   2. `ssh palworld 'cd ~/palworld && docker compose down'`
   3. `ssh root@homelab.internal 'qm shutdown 200 && qm set 200 --memory 16384 && qm start 200'`
   4. Copy the compose file over and start it (see `apps/palworld/README.md`).
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
   The friends' firewall rule depends on VM 200's address.
3. Ping each planned IP to make sure nothing already uses it.
4. Add AdGuard rewrites: `k3s-cp-1.internal`, `k3s-worker-1.internal` and
   `k3s-worker-2.internal`.
5. No firewall change needed. Friends' WireGuard rules already block the new
   nodes.

## Step 5: Secrets in 1Password

| Item | How to make it |
| --- | --- |
| Proxmox API token | Step 3 |
| State encryption passphrase | Long random string. If it's lost, the state can't be read. |
| k3s join token | `openssl rand -hex 32` |

Add `.env.tpl` files with `op://` references in `tofu/homelab/` and `ansible/`.
Run commands as `op run --env-file=.env.tpl -- <command>` so values never touch
disk.

## Step 6: Create the VMs with OpenTofu

Files in `tofu/modules/proxmox-vm/` and `tofu/homelab/`:

- `providers.tf`:
  - `bpg/proxmox`, pinned to a version.
  - Endpoint `https://homelab.internal:8006/`.
  - Token read from the `PROXMOX_VE_API_TOKEN` environment variable.
  - `insecure = true` while the host uses a self-signed certificate.
- `encryption.tf`: `pbkdf2` key provider plus `aes_gcm`, with
  `enforced = true` for both state and plan files.
- `image.tf`: download the Ubuntu 24.04 cloud image
  (`noble-server-cloudimg-amd64.img`) into `local` as `import` content.
- `nodes.tf`: the single source of truth for the nodes.

  ```hcl
  locals {
    nodes = {
      k3s-cp-1     = { vmid = 301, ip = "192.168.8.11", cores = 2, memory = 3072, role = "server", data_disk = 0 }
      k3s-worker-1 = { vmid = 311, ip = "192.168.8.12", cores = 8, memory = 4096, role = "agent",  data_disk = 100 }
      k3s-worker-2 = { vmid = 312, ip = "192.168.8.13", cores = 4, memory = 4096, role = "agent",  data_disk = 50 }
    }
  }
  ```

- Module settings for each VM:
  - CPU type `host`.
  - Memory with `floating = 0`, so ballooning is off.
  - Boot disk on `nvme-ssd-1tb` (qcow2), with `discard`, `ssd` and
    `iothread` enabled.
  - For workers, a second disk on `sata-ssd-1tb`.
  - Cloud-init snippet stored on `nvme-ssd-1tb`.
  - Static IP and DNS server `192.168.8.1` through cloud-init.
  - A user-data snippet that creates the user with the SSH key, installs
    `qemu-guest-agent`, and mounts the data disk at
    `/var/lib/rancher/k3s/storage` (local-path's default directory).
  - Guest agent on, and `on_boot = true`.
- `inventory.tf`: render `ansible/inventory/hosts.yml` from `local.nodes`
  with `templatefile`.

Run:

```bash
cd tofu/homelab
op run --env-file=.env.tpl -- tofu init
op run --env-file=.env.tpl -- tofu plan
op run --env-file=.env.tpl -- tofu apply
```

Check:

- `ssh austin@<node-ip>` works on all three nodes.
- The Proxmox UI shows each VM's IP from the guest agent.
- `head -c 20 terraform.tfstate` shows encrypted JSON, not readable resource
  data.

## Step 7: Install k3s with Ansible

Files in `ansible/`:

- `ansible.cfg`: points at the generated inventory and sets
  `StrictHostKeyChecking=accept-new`.
- `group_vars/all.yml`: `k3s_version` (a pinned stable release), the
  control plane IP, and `k3s_token: "{{ lookup('env', 'K3S_TOKEN') }}"`.
- `roles/base`:
  - Apply updates and set the timezone.
  - Enable `unattended-upgrades`, without automatic reboots.
  - Raise the `fs.inotify` limits.
  - Cap journald's disk use.
  - Check that swap is off.
- `roles/k3s_server`: write `/etc/rancher/k3s/config.yaml`, then run the
  install script with `INSTALL_K3S_VERSION`. Running it again must change
  nothing.

  ```yaml
  token: "{{ k3s_token }}"
  cluster-init: true          # embedded etcd: can add servers later, gets snapshots
  tls-san: [192.168.8.11, k3s-cp-1.internal]
  node-taint: ["node-role.kubernetes.io/control-plane:NoSchedule"]
  disable: [servicelb]        # replaced by MetalLB
  write-kubeconfig-mode: "0600"
  ```

- `roles/k3s_agent`: the same setup, with
  `server: https://192.168.8.11:6443` and the token.
- `playbooks/site.yml`: runs `base` on all nodes, then `k3s_server`, then
  `k3s_agent`. It ends by copying the cluster's kubeconfig to
  `~/.kube/homelab.yaml` (mode `0600`), with the server changed from
  `127.0.0.1` to the control plane IP and the context renamed to `homelab`.

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
- Running the playbook a second time reports zero changes.

## Step 8: MetalLB and storage test

1. Install MetalLB with Helm:

   ```bash
   helm repo add metallb https://metallb.github.io/metallb
   helm install metallb metallb/metallb -n metallb-system --create-namespace
   ```

2. Apply an `IPAddressPool` (192.168.8.50 - .59) and an `L2Advertisement`
   from `kubernetes/infra/metallb/`, so Argo CD can take them over later.
3. Load balancer test: deploy nginx with a `LoadBalancer` Service. It should
   get an IP from the pool, and `curl` should work from your PC. Traefik will
   also take a pool IP; that's expected.
4. Storage test: create a PVC and a pod pinned to `k3s-worker-1` that writes
   a file. Check the file shows up under `/var/lib/rancher/k3s/storage`.
5. Delete the test resources.

## Step 9: Rebuild from scratch

```bash
op run --env-file=.env.tpl -- tofu destroy
op run --env-file=.env.tpl -- tofu apply
op run --env-file=.env.tpl -- ansible-playbook playbooks/site.yml
```

Then reapply MetalLB. Phase 1 is done when this produces a working cluster with
no manual steps. Note how long the rebuild takes for the README.

## Step 10: Docs and CI

- Makefile targets: `plan`, `apply`, `cluster`, `kubeconfig`, `destroy`.
- `.github/workflows/lint.yml`: `tofu fmt -check`, `tofu validate`, `tflint`
  and `ansible-lint` on pull requests. Lint only; CI never runs `apply`.
- `docs/adr/`: k3s over Talos, one control plane, local encrypted state,
  MetalLB over servicelb, local-path over Longhorn.
- README: tick off roadmap items, add an architecture diagram, and add a
  "rebuild from zero" section.

---

## After phase 1

1. Argo CD, then hand MetalLB over to it.
2. Minecraft (`itzg/minecraft-server`, ~4GB heap, 5-6GB pod) as the first real
   workload.
3. Palworld cutover:
   - Stop VM 200 (it saves on SIGTERM).
   - `rsync` the `palworld/` directory into the new PVC. Don't bring
     `WorldOption.sav` along.
   - Run a StatefulSet with the same image and environment variables.
     `PUBLIC_IP` is the Service's fixed MetalLB IP, set with the
     `loadBalancerIPs` annotation, and the Service uses
     `externalTrafficPolicy: Local`.
   - Update the router firewall rule, the AdGuard record, and friends'
     WireGuard `AllowedIPs` if the IP changed.
   - Keep VM 200 stopped for a week as a rollback, then delete it and grow
     `k3s-worker-1` to 16GB.
4. Later: codify the router's WireGuard peers and firewall rules with Ansible.
   Move state to a remote backend when CI starts running `tofu`.