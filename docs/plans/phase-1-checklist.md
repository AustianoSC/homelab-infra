# Phase 1 checklist

- [ ] **0. Tidy up the repo:** sync the Palworld compose file with VM 200, update READMEs for WireGuard, stop ignoring `.terraform.lock.hcl`, move plans into `docs/plans/`, commit
- [x] **1. Install tools in WSL:** OpenTofu, Ansible, ansible-lint, kubectl, Helm
- [x] **2. Check the Proxmox host:** `pveversion`, `pvesm status`, `free -h`, `qm list`, `lsblk`
- [ ] **3. Prepare Proxmox:** shrink VM 200 to 16GB, `tofu@pve` user and API token, root SSH key access (storage already fine)
- [ ] **4. Network:** confirm the DHCP range, DHCP reservations for `.150` and `.119`, reserve node IPs `.11`-`.13` and MetalLB pool `.50`-`.59`, add AdGuard rewrites
- [ ] **5. Secrets and state bucket:** Proxmox token, state encryption passphrase, k3s join token, `.env.tpl` files; `tofu/bootstrap` creates the versioned S3 bucket and scoped IAM user, access key created by hand into 1Password, bootstrap state migrated into the bucket
- [ ] **6. OpenTofu:** S3 backend, provider, state encryption, cloud image, `nodes.tf`, VM module, inventory template, lock file for both platforms, then `tofu apply`
- [ ] **7. Ansible:** `base`, `k3s_server`, `k3s_agent` roles and the kubeconfig fetch, then `ansible-playbook site.yml`; all nodes `Ready`
- [ ] **8. Add-ons:** MetalLB with its IP pool, a load balancer test, a PVC test on a worker
- [ ] **9. Rebuild test:** `tofu destroy`, `tofu apply`, `ansible-playbook` with no manual steps
- [ ] **10. Docs and CI:** Makefile, lint workflow, ADRs, README updates

## After phase 1

- [ ] Argo CD
- [ ] Minecraft
- [ ] Palworld cutover (fixed MetalLB IP, copy the save, update firewall and DNS, retire VM 200, grow worker-1)
- [ ] Router WireGuard and firewall rules in Ansible