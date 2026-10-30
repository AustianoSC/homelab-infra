# Phase 4: WireGuard peers and firewall rules as code

Goal: the router's WireGuard peers and the firewall rules that decide what each
peer can reach are defined in this repo and applied with Ansible. "Done" means
adding a friend, or opening a new game to friends, is a change to one variables
file plus `make router`, the hand-made rules are gone, and a factory reset of
the router can be recovered from the repo and 1Password.

Today this is all hand-made in the GL.iNet admin UI: one WireGuard server, a
peer per person, and a firewall rule that lets peers reach the `games` block
(`192.168.8.48/29`), DNS and, for now, the old Palworld VM at `.119`.

## Decisions

| Topic | Decision | Why |
| --- | --- | --- |
| Tool | Ansible, a new `router` role and playbook, run from your machine | Same tool as the nodes. Push model from the LAN; CI never gets router credentials ([ADR 0007](../adr/0007-pull-based-gitops.md)) |
| How config is written | OpenWrt's `uci`, through a rendered `uci batch` file | GL.iNet firmware is OpenWrt underneath and `uci` is its supported config interface. A batch is applied all at once and can be diffed first |
| Python on the router | Not required; decided in step 1 | Most Ansible modules need Python on the target. If the router has room for `python3-light` the role can use normal modules; if not, `raw` + `uci batch` needs nothing installed |
| What the repo owns | Only sections it names: peers it lists, and firewall rules prefixed `homelab_` | The router keeps its own defaults, and the UI stays usable for everything else. The role deletes `homelab_*` sections that are no longer in the repo, and nothing else |
| Access model | Groups of peers, each with a list of destinations: `admin` (you: LAN), `players` (friends: DNS and the `games` block) | Per-person rules without repeating them per person. A new game is one destination in one group |
| Keys | The server's private key stays on the router and is never read by Ansible. Peer private and preshared keys live in 1Password, one item per peer | No secret is in Git. The router only needs each peer's public key and preshared key |
| Peer names | Nicknames (`friend-1`), not real names | The repo is public. Public keys and tunnel addresses aren't secret, but who your friends are isn't the internet's business |
| Existing peers | Imported as they are: same keys, same tunnel addresses | Nobody gets a new config, so friends notice nothing |
| Safety | Run over LAN SSH, never over WireGuard; `--check --diff` first; an automatic rollback timer on every apply | A bad firewall rule can cut off the connection that applies it |

## What changes in the repo

| Path | Change |
| --- | --- |
| `ansible/inventory/router.yml` | New, hand-written: the router (`192.168.8.1`). Separate from `hosts.yml`, which OpenTofu generates |
| `ansible/inventory/group_vars/router.yml` | New: WireGuard server settings, the peer list, the access groups and their destinations |
| `ansible/roles/router/` | New role: render the `uci batch`, back up, apply with a rollback timer, reload, verify |
| `ansible/playbooks/router.yml` | New playbook for the role |
| `Makefile` | New `router-check` (`--check --diff`) and `router` targets; `wg-client` to print a peer's client config |
| `ansible/templates/wg-client.conf.tpl` (or similar) | New: a client config with `op://` references, rendered with `op inject` when handing out a config |
| `docs/adr/0009-router-config-as-code.md` | New: the decisions above |
| `README.md`, `docs/bootstrap.md` | Router section: what is managed, how to add a peer, how to recover |

## Part 1: Find out what's there (read-only)

- [ ] **1. Inventory the router.** Over SSH from the LAN (`ssh root@192.168.8.1`),
  without changing anything. Don't paste private or preshared keys anywhere;
  the commands below filter them out.
  ```bash
  cat /etc/glversion /etc/openwrt_release        # firmware and OpenWrt base
  df -h /overlay                                  # room for python3-light?
  ls /etc/config
  uci show wireguard_server | grep -v -i key      # GL.iNet's WireGuard server config
  uci show network | grep -i -A3 wg | grep -v -i key
  uci show firewall                               # zones, forwardings, rules
  wg show | grep -v -i 'private\|preshared'       # live peers and handshakes
  ```
  Write down: the firmware version, which file holds the peers (on GL.iNet
  it's usually `wireguard_server`, and `network` is regenerated from it), the
  names of the WireGuard zone (for example `wgserver`) and LAN zone, each
  peer's public key and tunnel address, and every rule that mentions the
  WireGuard zone. Take a full backup in the admin UI (System, Backup) and keep
  it off the router.

- [ ] **2. Decide the method.** If `/overlay` has a few MB free and the firmware
  allows `opkg install python3-light`, use normal Ansible modules. If not, use
  `raw` and `uci batch`. Record the choice in ADR 0009. Either way the router
  needs your SSH public key (GL.iNet: System, Administration, or
  `/etc/dropbear/authorized_keys`), so `ssh root@192.168.8.1 true` works
  without a password.

## Part 2: Write it

- [ ] **3. Model the current state as variables.** In
  `ansible/inventory/group_vars/router.yml`, with nicknames (the addresses
  and keys below are placeholders):
  ```yaml
  wg_access_groups:
    admin:
      destinations:
        - { name: lan, dest_ip: 192.168.8.0/24 }
    players:
      destinations:
        - { name: dns,   dest_ip: 192.168.8.1,     proto: [udp, tcp], dest_port: 53 }
        - { name: games, dest_ip: 192.168.8.48/29, proto: [udp, tcp] }
        - { name: palworld-vm, dest_ip: 192.168.8.119, proto: [udp], dest_port: 8211 }  # until VM 200 is retired

  wg_peers:
    - { name: austin-laptop, group: admin,   address: 10.0.0.2/32, public_key: "..." }
    - { name: friend-1,      group: players, address: 10.0.0.3/32, public_key: "..." }
  ```
  The tunnel addresses and public keys are copied from step 1, so the peers
  that exist keep working unchanged. Preshared keys are read from 1Password at
  apply time (`op://homelab/wg-peer-<name>/preshared-key`), never written here.

- [ ] **4. Write the role.** It renders a `uci batch` from the variables:
  one section per peer in the WireGuard server config, and one firewall rule
  per group and destination, named `homelab_<group>_<destination>`, from the
  WireGuard zone to the LAN zone, restricted to that group's peer addresses
  (`src_ip`). It also deletes any `homelab_*` rule or listed-peer section that
  isn't in the variables. Then it:
  1. Saves the current `/etc/config/{wireguard_server,network,firewall}` to
     `/tmp/homelab-rollback/`.
  2. Starts a timer on the router: in 5 minutes, copy those files back and
     reload. This runs on the router itself, so it fires even if Ansible has
     lost the connection.
  3. Applies the batch, `uci commit`, and reloads the firewall and WireGuard.
  4. Checks from the router that it's still healthy (`wg show` lists the
     peers, the firewall reloaded without errors), then cancels the timer.

  `--check --diff` renders the batch and shows the difference against
  `uci show` without applying it. A second run with no variable changes must
  report no changes.

- [ ] **5. Add the Makefile targets.** `make router-check` and `make router`,
  both using `ansible/inventory/router.yml` and `op run` for the preshared
  keys, the same pattern as `make cluster`. `ansible-lint` in CI covers the
  new role automatically.

## Part 3: Switch over

- [ ] **6. Dry run.** `make router-check`. The diff should be empty, or only
  show the `homelab_*` rules being added next to the hand-made ones, because the
  variables describe what is already there. If it wants to change a peer, the
  variables are wrong; fix them first.

- [ ] **7. Apply with a test peer first.** Add a peer `test-phone` in the
  `players` group. Create its key pair (`wg genkey`, `wg pubkey`) and a
  preshared key (`wg genpsk`), and save the private and preshared keys in a
  1Password item `wg-peer-test-phone` without leaving them in a file or your
  shell history. Only the public key goes in the repo. Run `make router`. On the phone, off Wi-Fi (mobile data), check that
  `palworld.internal:8211` works and that `192.168.8.11` (a node) does **not**.
  That proves the group limits work.

- [ ] **8. Remove the hand-made rules.** Once the `homelab_*` rules work, delete
  the old hand-made WireGuard rules in the UI (or have the role delete them by
  name, once). Run `make router-check` again: no changes. Ask one friend to
  connect as a final check.

- [ ] **9. Hand out configs from the repo.** `make wg-client PEER=friend-2`
  prints a client config (or a QR code with `qrencode -t ansiutf8`) with the
  peer's private key, preshared key, the router's public key, the endpoint and
  `AllowedIPs = 192.168.8.1/32, 192.168.8.48/29`, rendered by `op inject` to
  the terminal, never to a file. Adding a friend becomes: create the 1Password
  item, add one line to `wg_peers`, `make router`, `make wg-client`.

- [ ] **10. Docs.** ADR 0009, README and `docs/bootstrap.md`: what the role
  owns, how to add or remove a peer, how to open a game, and how to recover
  after a factory reset (restore the UI backup or set up the WireGuard server,
  then `make router`).

## Rolling back

Within 5 minutes of an apply, doing nothing is the rollback: the timer restores
the previous files. After that, `/tmp/homelab-rollback/` on the router holds
the last previous config until a reboot, and the admin UI backup from step 1
restores everything.

## Notes

- **Firmware upgrades** can reset packages, and sometimes config. After one,
  run `make router-check` to see what drifted, then `make router`.
- **Editing in the UI** is still possible, but a peer or `homelab_*` rule
  changed there is overwritten on the next `make router`. Change those in Git.
- **VM 200:** retiring it (phase 2, step 12) becomes deleting the
  `palworld-vm` destination and running `make router`.
- **DNS and DHCP** (AdGuard rewrites like `palworld.internal`, DHCP
  reservations) are on the same router and could be managed the same way later.
  They're left out to keep this phase small.

## After phase 4

1. Observability (VictoriaMetrics and Grafana).
2. Nice to have: off-host backups of the Palworld volume, and Reloader.
