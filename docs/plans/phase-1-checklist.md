# Phase 1 checklist

- [ ] **0. Tidy up the repo:** sync the Palworld compose file with VM 200, update READMEs for WireGuard, stop ignoring `.terraform.lock.hcl`, move plans into `docs/plans/`, commit
- [x] **1. Install tools in WSL:** OpenTofu, Ansible, ansible-lint, kubectl, Helm
- [x] **2. Check the Proxmox host:** `pveversion`, `pvesm status`, `free -h`, `qm list`, `lsblk`
- [ ] **3. Prepare Proxmox:** copy the Palworld save off, shut down VM 200 with `onboot 0` and a `vzdump` backup, `tofu@pve` user and API token, root SSH key access (storage already fine)
- [ ] **4. Network:** confirm the DHCP range, DHCP reservations for `.150` and `.119`, reserve node IPs `.11`-`.13` and MetalLB pools `192.168.8.48/29` (games) and `192.168.8.56/29` (general), add AdGuard rewrites
- [ ] **5. Secrets and state bucket:** Proxmox token, state encryption passphrase, k3s join token, `.env.tpl` files; `tofu/bootstrap` creates the versioned S3 bucket and scoped IAM user, access key created by hand into 1Password, bootstrap state migrated into the bucket
- [ ] **6. OpenTofu:** code written and validated in `infra/` (S3 backend, encryption, provider, image, nodes, VM module, inventory, lock file for both platforms); still to do: `tofu plan`, `tofu apply`, checks
- [ ] **7. Ansible:** `base`, `k3s_server`, `k3s_agent` roles and the kubeconfig fetch, then `ansible-playbook site.yml`; all nodes `Ready`
- [ ] **8. Add-ons:** MetalLB with its IP pool, a load balancer test, a PVC test on a worker
- [ ] **9. Rebuild test:** `tofu destroy`, `tofu apply`, `ansible-playbook` with no manual steps
- [ ] **10. Docs and CI:** Makefile, lint workflow, ADRs, README updates

## After phase 1

- [ ] Argo CD
- [ ] Minecraft at `.49`; add `192.168.8.48/29` to the firewall rule and friends' `AllowedIPs`
- [ ] Palworld cutover (pinned to `.48`, copy the save into the PVC, update DNS, retire VM 200)
- [ ] Router WireGuard and firewall rules in Ansible