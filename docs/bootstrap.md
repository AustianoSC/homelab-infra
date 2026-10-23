# One-time setup

What has to exist before `make up` works. Do this once per environment; none of
it is managed by this repo, because it is what the repo's own tooling needs.

## Tools

On the WSL desktop, install OpenTofu (the `deb` method from
[opentofu.org](https://opentofu.org/docs/intro/install/)), Ansible and
ansible-lint through `pipx`, and `kubectl`, `helm`, the 1Password CLI and the
AWS CLI from their own docs. On macOS:

```bash
brew install opentofu ansible ansible-lint kubectl helm 1password-cli awscli tflint pre-commit
```

On every machine, run `make hooks` once in the clone, to install the git
pre-commit hooks (see the README).

## Proxmox

1. Create an API user and token for OpenTofu, on the Proxmox host (not in a VM):

   ```bash
   pveum user add tofu@pve --comment "OpenTofu"
   pveum role add TofuProvisioner --privs "<privileges from the bpg/proxmox docs for your PVE version>"
   pveum acl modify / --users tofu@pve --roles TofuProvisioner
   pveum user token add tofu@pve provider --privsep 0
   ```

2. Store the token in 1Password as the **full string**
   `tofu@pve!provider=<secret>`, not just the secret. The provider rejects
   anything else ("must be in the format USER@REALM!TOKENID=UUID").
3. The provider also uploads cloud-init snippets over SSH as root, and it only
   reads `ssh-agent`, not `~/.ssh/config`. Put your public key in root's
   `authorized_keys` on the host, then on each machine:

   ```bash
   ssh-add ~/.ssh/id_ed25519
   ssh-add -L          # the key must be listed
   ```

   An empty agent shows up as `EOF` or `connection reset` during `tofu apply`,
   and repeated failures make sshd back off for a while.
4. A machine that isn't the one that first applied needs its public key in
   `local.ssh_public_keys` in `infra/access.tf`, then an apply, so every machine
   renders identical cloud-init.

The storage names used in `infra/nodes.tf` (`nvme-ssd-1tb`, `sata-ssd-1tb`) must
exist on the host as directory storages with `images` and `snippets` enabled,
and `local` must allow `import` for the Ubuntu cloud image.

## Network

- The router's DHCP pool must not overlap the node addresses
  (`192.168.8.11` - `.13`) or the MetalLB pools (`192.168.8.48/29` and
  `192.168.8.56/29`). The GL.iNet default pool is `.100` - `.249`.
- Give the Proxmox host a DHCP reservation, since it sits inside that pool.
- Add AdGuard rewrites for `k3s-cp-1.internal`, `k3s-worker-1.internal` and
  `k3s-worker-2.internal`.

## Secrets (1Password, vault `homelab`)

| Item | Field | Used by | Notes |
| --- | --- | --- | --- |
| `proxmox-tofu` | `token` | OpenTofu | The full token string, see above |
| `tofu-state` | `password` | OpenTofu | The state encryption passphrase. **If it's lost the state can't be read.** |
| `k3s` | `password` | Ansible | The cluster join token. It is baked in at install time, so it can't be changed later |
| `palworld` | `server-password`, `admin-password` | `make palworld-secret` | |
Generate the two random ones with:

```bash
op item create --vault homelab --category password --title tofu-state --generate-password='64,letters,digits'
op item create --vault homelab --category password --title k3s --generate-password='64,letters,digits'
```

## State bucket (AWS)

State lives in the versioned S3 bucket named in `infra/backend.tf`, reached
through an AWS SSO profile (no long-lived access key). For example:

```bash
aws s3api create-bucket --bucket lab-terratofu-state --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2
aws s3api put-bucket-versioning --bucket lab-terratofu-state \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket lab-terratofu-state \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Then `aws sso login --profile austin-sandbox` before any OpenTofu command, with
`AWS_PROFILE=austin-sandbox` exported. The state is also encrypted client-side,
so the bucket never holds readable state. See
[ADR 0004](adr/0004-encrypted-state-in-s3.md).

## Then

Make the repo public (Argo CD pulls it without credentials), then run
`make up`. The GitOps and Palworld steps are in
[the phase 2 plan](plans/phase-2-gitops-palworld.md).
