# Phase 1 checklist

- [x] **0. Tidy up the repo:** Palworld compose file synced with VM 200, READMEs updated for WireGuard, `.terraform.lock.hcl` committed, plans moved into `docs/plans/`
- [x] **1. Install tools in WSL:** OpenTofu, Ansible, ansible-lint, kubectl, Helm
- [x] **2. Check the Proxmox host:** `pveversion`, `pvesm status`, `free -h`, `qm list`, `lsblk`
- [x] **3. Prepare Proxmox:** Palworld save copied to `~/backups/palworld-2026-10-14`, VM 200 stopped with `onboot 0` and a `vzdump` backup on `hdd-2tb`, `tofu@pve` user and `provider` API token, root SSH key access (storage needed no changes)
- [x] **4. Network:** DHCP pool is `.100`-`.249`; reservations for `.150` (Proxmox) and `.119` (VM 200); node IPs `.11`-`.13` and MetalLB pools `192.168.8.48/29` (games) and `192.168.8.56/29` (general) sit outside it; AdGuard rewrites for all three nodes
- [x] **5. Secrets and state bucket:** Proxmox token, state encryption passphrase and k3s join token in 1Password, `.env.tpl` files in `infra/` and `ansible/`; S3 bucket `lab-terratofu-state` (versioned, public access blocked, encrypted) created with the AWS CLI and accessed through AWS SSO, so no bootstrap stack or IAM user
- [x] **6. OpenTofu:** `infra/` (S3 backend, encryption, provider, image, nodes, VM module, inventory, lock file for both platforms), applied and verified from WSL and the MacBook
- [x] **7. Ansible:** `base`, `k3s_server`, `k3s_agent` roles and the kubeconfig fetch; `ansible-playbook site.yml` run, all nodes `Ready`
- [x] **8. Add-ons:** MetalLB `0.16.1` from `kubernetes/infra/metallb/` (BGP backend off), `games` and `general` pools, load balancer and IP-pinning tests, PVC test on a worker
- [ ] **9. Rebuild test:** `tofu destroy`, `tofu apply`, `ansible-playbook`, reinstall MetalLB, with no manual steps
- [x] **10. Docs and CI:** `Makefile` (`make help`), `lint.yml` (OpenTofu, tflint, ansible-lint, gitleaks; lint only), seven ADRs in `docs/adr`, README with architecture diagrams and run/destroy/rebuild instructions. The workflow's first real run happens on GitHub when this is pushed

## After phase 1

- [ ] Argo CD
- [ ] Minecraft at `.49`; add `192.168.8.48/29` to the firewall rule and friends' `AllowedIPs`
- [ ] Palworld cutover (pinned to `.48`, copy the save into the PVC, update DNS, retire VM 200)
- [ ] Router WireGuard and firewall rules in Ansible
