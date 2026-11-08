# Phase 4: WireGuard peers and firewall rules as code

Goal: the router's WireGuard peers and the firewall rules that decide what each
peer can reach are defined in this repo and applied with Ansible. "Done" means
adding a friend, or opening a new game to friends, is a change to one variables
file plus `make router`, the hand-made rules are gone, and a factory reset of
the router can be recovered from the repo and 1Password.

Today this is all hand-made in the GL.iNet admin UI: one WireGuard server and
six peers (two of mine, two of my girlfriend's, two friends'). Friends and my
girlfriend can reach the `games` block (`192.168.8.48/29`) and, for now, the old
Palworld VM at `.119`. Only my devices can reach the rest of the LAN and the
router itself.

## What step 1 found

Recorded on 2026-11-05. No keys are listed here; public keys go in
`group_vars/router.yml` in step 4.

- Firmware GL.iNet 4.10.1 on OpenWrt 23.05-SNAPSHOT (aarch64, `ipq53xx`).
`/overlay` has 6.3 GB free and `opkg` works, but there's no Python.
- Peers live only in `/etc/config/wireguard_server`, as sections `peer_<id>`.
`network.wgserver` is a GL.iNet interface (`proto wgserver`) that points at
`main_server` and holds no peers.
- Firewall zones: `wgserver` (WireGuard) and `lan`. `wgserver2lan` is disabled,
so a peer reaches the LAN only through explicit rules. The design relies on
that.
- The router stores every peer's `private_key` (GL.iNet generates the client
configs). No peer has a preshared key, only a `presharedkey_enable` flag.
- No WireGuard init script exists; the tunnel is a netifd interface, built by
`/lib/netifd/proto/wgserver.sh`. On every `ifup` it rewrites
`/tmp/wireguard/wgserver` from `wireguard_server` and runs `wg setconf`, so
adding or changing a peer needs the interface brought down and up (all peers
reconnect within seconds). That script reads only these peer options:
`public_key`, `presharedkey`, `client_ip`, `deprecated` and `enabled`. The
server-side `AllowedIPs` of a peer is its `client_ip`. The `allowed_ips`,
`dns` and `mtu` options are only used by the GL.iNet UI to build client
configs. The script also runs `/etc/wireguard/scripts/before_wgserver_ifup.sh`
and `after_wgserver_if_down.sh`, which call `wgserver_func.sh` with
`set_firewall` and `set_dhcp up` on start, and `disabled_firewall` and
`set_dhcp down` on stop. A tunnel restart therefore reloads the firewall
twice (once with GL.iNet's zone disabled), commits `firewall` and `dhcp`, and
reloads dnsmasq, which can blip DNS for the whole LAN.
`server_set_firewall` in `/lib/functions/vpn_server_func.sh` writes only
these named sections: the zone `wgserver`, and the rules and forwardings
`wgserver_allow`, `wgserver2lan`, `wgserver2wan`, `lan2wgserver`,
`wgserver2wgserver` and `wgserver_allow_dns`. It never touches `homelab_*`
or the hand-made rules.
- The server option `access` drives GL.iNet's "allow peers to the LAN" switch:
`ACCEPT` makes the zone's `input` ACCEPT and enables `wgserver2lan` (every
peer reaches the whole LAN); today it is `DROP`, so `wgserver2lan` is off.
The whole group design depends on that staying `DROP`, so the role never
changes `access` and fails if it isn't `DROP`.
- Nothing under `/usr/bin`, `/usr/sbin`, `/etc/init.d`, `/lib/netifd/proto`,
`/lib/functions` or `/etc/wireguard/scripts` mentions `allow_admin_access`,
so a tunnel restart doesn't create those two rules. They were made by hand
in the UI, like the two game rules.
- Firewall order, from `nft list chain inet fw4 forward_wgserver`: all rules
come first, in config order, then the forwardings (`wgserver2wan`), then a
final reject. So a `homelab_*` reject rule to `wan` is evaluated before
GL.iNet's `wgserver2wan` accept, and the `no-internet` rule can work. The
hand-made game rules have 0 packets, so nothing has used them since the last
firewall reload.
- The router's SSH key is already in `/etc/dropbear/authorized_keys`.

| Nickname | Section | Tunnel address | Client `allowed_ips` | Group |
| --- | --- | --- | --- | --- |
| `my-iphone` | `peer_1785` | `10.0.0.2` | `0.0.0.0/0` | admin |
| `my-macbook` | `peer_6995` | `10.0.0.3` | `0.0.0.0/0` | admin |
| `gf-iphone` | `peer_648` | `10.0.0.4` | `0.0.0.0/0` | tunnel |
| `gf-macbook` | `peer_7681` | `10.0.0.5` | `0.0.0.0/0` | tunnel |
| `friend-1` | `peer_6738` | `10.0.0.6` | `10.0.0.1/32, 192.168.8.119/32, 192.168.8.48/29` | players |
| `friend-2` | `peer_3489` | `10.0.0.7` | `10.0.0.1/32, 192.168.8.119/32, 192.168.8.48/29` | players |

Hand-made rules that mention `wgserver` (the ones this phase replaces):

- `allow_admin_access_device`: `.2` and `.3` to the router itself, all protocols.
- `allow_admin_access_lan`: `.2` and `.3` to the LAN, all protocols.
- `allow_wg_to_palworld`: all of `10.0.0.0/24` to `192.168.8.119:8211/udp`.
- `allow_wg_to_games_subnet` (the name has a leading space): all of
`10.0.0.0/24` to `192.168.8.48/29`.
- Three empty, nameless `rule` sections (leftovers) to clean up.

GL.iNet's own rules stay as they are: `wgserver_allow` (WAN to port 51820),
`wgserver_allow_dns` (any peer to the router on port 53), `wgserver2wan`,
`lan2wgserver` and `wgserver2wgserver`.

## Decisions

| Topic | Decision | Why |
| --- | --- | --- |
| Tool | Ansible, a new `router` role and playbook, run from your machine | Same tool as the nodes. Push model from the LAN; CI never gets router credentials ([ADR 0007](../adr/0007-pull-based-gitops.md)) |
| How config is written | OpenWrt's `uci`: the role renders one shell script (`files/apply.sh` plus the settings and the desired state), sends it with the `script` module over a piped SSH transfer (the router has no SFTP) and runs it. The script builds a `uci batch`, tries it on a copy of the config, and only then applies it | GL.iNet firmware is OpenWrt underneath and `uci` is its supported config interface. A batch is applied all at once, and the copy gives the diff for `make router-check` without touching the live config |
| Python on the router | Not used: a shell script + `uci batch` | The room is there, but a GL.iNet firmware upgrade can remove installed packages, and nothing here needs Python |
| What the repo owns | Peers it lists (by `peer_<id>`) and firewall rules prefixed `homelab_` | The router keeps its own defaults, and the UI stays usable for everything else. The role deletes `homelab_*` rules that are no longer in the repo, and peers marked `state: absent`, and nothing else |
| Access model | Three groups, each with a list of destinations: `admin` (my devices: the LAN and the router itself), `tunnel` (my girlfriend: the `games` block and Palworld, plus internet through the router), `players` (friends: the `games` block and Palworld only) | Per-person rules without repeating them per person. A new game is one destination in one group |
| Peer keys | Every peer's private key goes in 1Password, one item per peer, admin peers included. The repo and the apply need only public keys. No preshared keys | `wg-client` and recovery work from 1Password for any peer, with no special case. The vault already holds higher-value credentials. Existing peers have no preshared key, and adding one on the router would break their configs |
| Router-held keys | Every private key already on the router (the server's and the imported peers') stays there, and the role never reads, writes or deletes them. They are not the only copy: see the 1Password copies above and the server key below | The router is the source GL.iNet builds its own client configs from, and nothing in this phase removes that |
| Server key | Stays on the router and is never read by Ansible. One manual copy goes in 1Password (item `wg-server`) | Losing it means reissuing every client config, and the router is the only other place it lives besides the UI backup |
| Peer names | Nicknames (`my-iphone`, `friend-1`), not real names | The repo is public. Public keys and tunnel addresses aren't secret, but who your friends are isn't the internet's business |
| Existing peers | Imported as they are: same section, same keys, same tunnel addresses. The role never touches their `private_key` | Nobody gets a new config, so friends notice nothing |
| Safety | Run over LAN SSH, never over WireGuard; `make router-check` first; an automatic rollback timer on every apply | A bad firewall rule can cut off the connection that applies it |

Two firewall facts the design depends on:

- **Forwarded versus input traffic.** A peer reaching a machine behind the
router (a node, a game server) is *forwarded*, and a rule for it has a `dest`
zone (`lan`). A peer reaching the router itself (DNS, SSH, the admin UI) is
*input*, and a rule for it has no `dest`. A rule with `dest: lan` and
`dest_ip: 192.168.8.1` never matches traffic to the router. That's why the
`admin` group has a `router` destination of a different kind, and why
`players` has no DNS destination: GL.iNet's `wgserver_allow_dns` already lets
every peer ask the router for DNS at `10.0.0.1`.
- **Client config versus firewall.** `allowed_ips` on a peer is what goes into
that peer's client config (which traffic it sends into the tunnel). It isn't
enforcement, and changing it on the router doesn't change a device that
already has its config. The firewall rules are the enforcement.

## What changes in the repo

| Path | Change |
| --- | --- |
| `ansible/inventory/router.yml` | New, hand-written: the router (`192.168.8.1`). Separate from `hosts.yml`, which OpenTofu generates |
| `ansible/inventory/group_vars/router.yml` | New: WireGuard server settings, the peer list, the access groups and their destinations |
| `ansible/roles/router/` | New role: validate the variables, render the apply script, back up, apply with a rollback timer, reload, verify. Also the client config template |
| `ansible/playbooks/router.yml` | New playbook for the role |
| `Makefile` | New `router-check` (`--check`, which prints its own diff) and `router` targets; `wg-client` to print a peer's client config |
| `ansible/roles/router/templates/wg-client.conf.j2`, `ansible/playbooks/wg-client.yml` | New: a client config with `op://` references for the private key and the endpoint, rendered with `op inject` when handing out a config |
| `docs/adr/0009-router-config-as-code.md` | New: the decisions above |
| `README.md`, `docs/bootstrap.md` | Router section: what is managed, how to add a peer, how to recover |

## Part 1: Find out what's there (read-only)

- [x] **1. Inventory the router.** Over SSH from the LAN (`ssh root@192.168.8.1`),
  without changing anything. Don't paste private keys anywhere; the commands
  below filter them out.
  ```bash
  cat /etc/glversion /etc/openwrt_release        # firmware and OpenWrt base
  df -h /overlay                                  # room for python3-light?
  ls /etc/config
  uci show wireguard_server | grep -v -i key      # GL.iNet's WireGuard server config
  uci show network | grep -i -A3 wg | grep -v -i key
  uci show firewall                               # zones, forwardings, rules
  wg show | grep -v -i 'private\|preshared'       # live peers and handshakes
  ```
  Then these, to finish the inventory:
  ```bash
  uci show wireguard_server | grep presharedkey_enable   # expect '0' on every peer
  ls /lib/netifd/proto | grep -i wg                      # how the tunnel is brought up
  grep -rl wireguard_server /lib/netifd /usr/bin /usr/sbin /lib/functions 2>/dev/null
  grep -rl allow_admin_access /usr /etc /lib 2>/dev/null  # does GL.iNet recreate these rules?
  nft list chain inet fw4 forward_wgserver               # rule order for the no-internet rule
  ls /tmp/wireguard                                      # names only; don't cat, it holds keys
  cat /etc/wireguard/scripts/before_wgserver_ifup.sh     # firewall changes on tunnel start
  cat /etc/wireguard/scripts/after_wgserver_if_down.sh
  cat /etc/wireguard/scripts/wgserver_func.sh            # done: see "What step 1 found"
  cat /lib/functions/vpn_server_func.sh                  # done: see "What step 1 found"
  cat /lib/netifd/proto/wgserver.sh                      # done: see "What step 1 found"
  ```
  Write down: the firmware version, which file holds the peers, the names of the
  WireGuard and LAN zones, each peer's public key and tunnel address, every rule
  that mentions the WireGuard zone, and **how to apply peer changes**: the
  config is only rebuilt by `ifup wgserver`, but that restarts every tunnel and
  reloads dnsmasq, so the role instead changes the live interface with
  `wg set wgserver peer <public key> allowed-ips <address>` (and
  `... remove`) next to the `uci` change, which is what `ifup` would produce.
  Findings are in "What step 1 found" above.
  Take a full backup and keep it off the router. In the admin UI
  (`http://192.168.8.1`), System, then Backup (called "Backup and Restore" on
  some versions), then download. Or from your machine:
  ```bash
  ssh root@192.168.8.1 'sysupgrade -b /tmp/backup.tar.gz'
  scp root@192.168.8.1:/tmp/backup.tar.gz ~/gl-be9300-backup-$(date +%F).tar.gz
  ssh root@192.168.8.1 'rm /tmp/backup.tar.gz'
  ```
  The LuCI backup (System, Backup / Flash Firmware, Generate archive) works
  too. Write it to `/tmp`, not `/root`: `/root` is on flash and keeps the file.
  Check the copy on your machine with
  `tar tzf <backup> | grep -e config/wireguard_server -e config/firewall`.
  The backup contains every peer's private key. Keep it in 1Password or on an
  encrypted disk, and never in this repo.

- [x] **2. Confirm SSH access.** The router already has your SSH key. From your
  machine, `ssh -o PasswordAuthentication=no root@192.168.8.1 true` must work
  without a password prompt. Record the method (a shell script + `uci batch`) in ADR 0009.
  Done. The router's SSH server has no post-quantum key exchange, so every
  connection prints a warning on stderr. Put `-o LogLevel=error` in the
  inventory's `ansible_ssh_common_args` so it doesn't end up in task output.
  Use the address (`ansible_host: 192.168.8.1`, `ansible_user: root`) rather
  than the `router` alias in your `~/.ssh/config`, which CI and others don't have.

## Part 2: Write it

- [x] **3. Copy every peer's private key into 1Password.** All six: `my-iphone`,
  `my-macbook`, `gf-iphone`, `gf-macbook`, `friend-1` and `friend-2`. One item
  per peer, named `wg-peer-<nickname>`, with the key in the item's `password` field (a `PASSWORD` item must have one,
  and it matches `k3s/password` and the other items).
  This lets `make wg-client` reprint any peer's config, with no special case
  for admin peers, and means recovery doesn't depend on the UI backup alone.
  The keys go from the router straight into `op` through a pipe, so they are
  never printed, written to a file, or put in your shell history or in a
  process's arguments. Needs `op` signed in, `jq`, and `wg` (`brew install jq wireguard-tools`). In zsh, from your machine:
  ```zsh
  peers=(my-iphone:peer_1785 my-macbook:peer_6995 gf-iphone:peer_648
         gf-macbook:peer_7681 friend-1:peer_6738 friend-2:peer_3489)
  for p in $peers; do
    ssh -o LogLevel=error root@192.168.8.1 \
      "uci -q get wireguard_server.${p##*:}.private_key" \
    | jq -Rn --arg t "wg-peer-${p%%:*}" \
        '{title:$t, category:"PASSWORD",
          fields:[{id:"password", label:"password", purpose:"PASSWORD", type:"CONCEALED", value:input}]}' \
    | op item create --vault homelab - >/dev/null && echo "created wg-peer-${p%%:*}"
  done
  ```
  Also copy the server's private key into an item `wg-server`. After a factory
  reset, setting that key back means every existing client config keeps
  working:
  ```zsh
  ssh -o LogLevel=error root@192.168.8.1 'uci -q get wireguard_server.main_server.private_key' \
  | jq -Rn '{title:"wg-server", category:"PASSWORD",
             fields:[{id:"password", label:"password", purpose:"PASSWORD", type:"CONCEALED", value:input}]}' \
  | op item create --vault homelab - >/dev/null && echo "created wg-server"
  ```
  Then check that each stored key matches the public key the router is
  actually using (the public keys are from `wg show` in step 1):
  ```zsh
  typeset -A pub=(
    my-iphone  'Jrdk7vnadOQ1xCwSm4/acfV6R64VRQf+75cya6zU0Ds='
    my-macbook 'bgIkulLvR4TiZ4/OPrrX2JlapxhYBiZxNGceAQB/oz0='
    gf-iphone  'pFbHrQVjLzgW7iQnZYEF0YXW/F1UodI6vHfdi+bM1Ck='
    gf-macbook 'MUr5lPYFHYQ18qBKJ22XbJlORday1Ez87wkX2roCVQk='
    friend-1   'qwUboSflNlUu0Q2ZxYtwYmP1eSqRrKZ3Iky8tXTnd3U='
    friend-2   'oJgJXUZj0+SpDY+01KRBXBq0Oh+rPQPR/oBbPyvVxzU=')
  for n k in ${(kv)pub}; do
    [[ "$(op read "op://homelab/wg-peer-$n/password" | wg pubkey)" == "$k" ]] \
      && echo "ok        $n" || echo "MISMATCH  $n"
  done
  [[ "$(op read op://homelab/wg-server/password | wg pubkey)" == 'SbnfkrS1PsoPfGlogJhDF5ZaHJv99luAPKlBaFDXAG8=' ]] \
    && echo "ok        wg-server" || echo "MISMATCH  wg-server"
  ```
  All seven must say `ok`. If `op item create -` isn't accepted by your `op`
  version, use `--template=/dev/stdin` in its place.
  Admin keys grant the whole LAN and the router, so protect that vault the same
  as the Proxmox and cluster credentials already in it. If a device is lost or
  stolen, don't restore its key: make a new key pair as in step 8, replace the
  peer, and remove the old one.

- [x] **4. Model the current state as variables.** Done. In
  `ansible/inventory/group_vars/router.yml`, with nicknames (keys are
  placeholders; copy the real public keys and addresses from step 1):
  ```yaml
  wg_server:
    tunnel_ip: 10.0.0.1                 # also the DNS server in client configs
    public_key: "..."                   # for client configs
    # The public endpoint isn't here: this repo is public. It is the `endpoint`
    # field of the 1Password item `wg-server`, read by `make wg-client`.

  wg_game_destinations: &game_destinations
    - { name: games,       to: lan, dest_ip: 192.168.8.48/29, proto: [tcp, udp, icmp] }
    - { name: palworld-vm, to: lan, dest_ip: 192.168.8.119,   proto: [udp], dest_port: 8211 }  # until VM 200 is retired

  wg_access_groups:
    admin:
      internet: true                    # clients send everything through the router
      destinations:
        - { name: lan,    to: lan,    dest_ip: 192.168.8.0/24 }   # forwarded
        - { name: router, to: router }                            # the router itself (input)
    tunnel:
      internet: true
      destinations: *game_destinations
    players:
      internet: false                   # client config routes only the destinations
      destinations: *game_destinations

  wg_peers:
    - { name: my-iphone,  peer_id: 1785, group: admin,   address: 10.0.0.2/32, public_key: "..." }
    - { name: my-macbook, peer_id: 6995, group: admin,   address: 10.0.0.3/32, public_key: "..." }
    - { name: gf-iphone,  peer_id: 648,  group: tunnel,  address: 10.0.0.4/32, public_key: "..." }
    - { name: gf-macbook, peer_id: 7681, group: tunnel,  address: 10.0.0.5/32, public_key: "..." }
    - { name: friend-1,   peer_id: 6738, group: players, address: 10.0.0.6/32, public_key: "..." }
    - { name: friend-2,   peer_id: 3489, group: players, address: 10.0.0.7/32, public_key: "..." }
  ```
  `peer_id` is the number in the section name (`peer_1785`); new peers get an
  unused number. The tunnel addresses and public keys are copied from step 1, so
  the peers that exist keep working unchanged. Nothing secret is in this file.
  To remove a peer, change its entry to `state: absent` and run `make router`.
  The destinations are in the order friends' existing `allowed_ips` list them
  (`palworld-vm`, then `games`), so a client config rendered from this file
  matches the one on the device.

- [x] **5. Write the role.** Done. It renders a `uci batch` from the variables:
  - One section per peer in `wireguard_server`, named `peer_<peer_id>`, setting
  `name`, `peer_id`, `public_key`, `client_ip`, `dns` (the server's tunnel
  IP), `mtu` (1420), `persistent_keepalive` (25) and `allowed_ips`. For a
  group with `internet: true`, `allowed_ips` is `0.0.0.0/0`; otherwise it's the
  tunnel IP plus the `dest_ip` of the group's `to: lan` destinations (which
  reproduces what friends have today). It never reads or writes `private_key`
  or `presharedkey_enable` on a peer that already exists.
  - One firewall rule per group and destination, named
  `homelab_<group>_<destination>`, from the `wgserver` zone, restricted to
  that group's peer addresses (`src_ip`). `to: lan` rules have `dest` set to
  the LAN zone and `dest_ip`; `to: router` rules have no `dest`.
  - For a group with `internet: false`, a `homelab_<group>_no_internet` rule
  rejecting traffic from its peers to the `wan` zone, so a friend editing
  their client config can't use the router as an exit. Step 8 checks that it
  takes effect over GL.iNet's `wgserver2wan` forwarding.
  - It deletes any `homelab_*` rule that isn't in the variables, and peers marked
  `state: absent`.
  Then it:
  1. Saves the current `/etc/config/{wireguard_server,network,firewall}` to

     `/tmp/homelab-rollback/`.
  2. Starts a timer on the router: in 5 minutes, copy those files back and

     reload. This runs on the router itself, so it fires even if Ansible has
       lost the connection.
  3. Applies the batch, `uci commit`, and reloads the firewall. For peers that

     were added, changed or removed, it also updates the live tunnel with
       `wg set wgserver peer <public key> allowed-ips <address>` or
       `... remove` (reading a removed peer's public key from `uci` first), so
       other peers aren't dropped and GL.iNet's start/stop scripts don't run.
       Everything is committed in one go, never staged across a tunnel restart,
       because those scripts run `uci commit firewall` too. An explicit
       `-e router_wg_restart=true` does the full `ifdown wgserver; ifup wgserver`
       instead.
  4. Checks from the router that it's still healthy (`wg show` lists the

     peers, the firewall reloaded without errors), then cancels the timer.
  `make router-check` (`--check`) runs the script as far as the comparison and
  stops: it prints what would change, compared with the live config, and
  `HOMELAB_RESULT=changed` or `nochange`. Nothing is written to the router
  (the script is staged in `/tmp` and removed). A second run with no variable
  changes must report no changes. The role refuses to run if the UI's
  "allow access to the local network" switch (`access`) is on, if there are
  uncommitted `uci` changes, or if the rollback timer can't be started.

- [x] **6. Add the Makefile targets.** Done. `make router-check` and `make router`,
  both using `ansible/inventory/router.yml`, the same pattern as `make cluster`
  but without `op run`: the apply needs only public keys. `make wg-client`
  (step 10) is the only target that reads 1Password. `ansible-lint` in CI covers
  the new role automatically.

## Part 3: Switch over

- [x] **7. Dry run.** Done: against the real router the only changes were the
  six peers' `name` and the seven new `homelab_*` rules (`homelab_admin_lan`,
  `homelab_admin_router`, `homelab_tunnel_games`, `homelab_tunnel_palworld_vm`,
  `homelab_players_games`, `homelab_players_palworld_vm`,
  `homelab_players_no_internet`), nothing about a key, address or
  `allowed_ips`. That is the expected result, because the variables describe
  what is already there. Run `make router-check` yourself before step 8. If it
  ever wants to change a key, an address or an `allowed_ips`, the variables are
  wrong; fix them first.

- [x] **8. Apply with a test peer first.** First add the public endpoint to
  1Password, for the client configs (`make wg-client` needs it):
  `op item edit wg-server --vault homelab 'endpoint[text]=<host>:51820'`.
  Then add a peer `test-phone` in the
  `players` group. Create its key pair and save the private key in a 1Password
  item `wg-peer-test-phone`; the key lives only in a shell variable, never in a
  file or your history. Only the public key goes in the repo:
  ```zsh
  key=$(wg genkey)
  print -r -- "$key" \
  | jq -Rn '{title:"wg-peer-test-phone", category:"PASSWORD",
             fields:[{id:"password", label:"password", purpose:"PASSWORD", type:"CONCEALED", value:input}]}' \
  | op item create --vault homelab - >/dev/null
  print -r -- "$key" | wg pubkey
  unset key
  ```
  The last `wg pubkey` prints the public key to copy into `wg_peers`. Don't
  paste a `# comment` after a command in an interactive zsh: it doesn't treat
  `#` as a comment there, so the words become arguments (`wg pubkey` then
  prints its usage and no key). If the item already exists, don't run the
  block again, since 1Password allows two items with one name; read the key
  back instead: `op read op://homelab/wg-peer-test-phone/password | wg pubkey`.
  Run `make router-check` and read the diff, then `make router`. Get the
  test phone's config with `make wg-client PEER=test-phone QR=1` (needs
  `qrencode`; otherwise leave `QR=1` off and copy the text) and scan it. On the phone, off Wi-Fi (mobile data), check:
  - `palworld.internal:8211` works,
  - `192.168.8.11` (a node) does **not**,
  - with the client's `AllowedIPs` set to `0.0.0.0/0`, internet through the
  tunnel does **not** work (the `homelab_players_no_internet` rule),
  - the peer appears in the GL.iNet UI. If GL.iNet's scripts need a
  `private_key` on the peer, add it to the role's output for new peers, which
  makes `make router` read 1Password.
  Then, once, at a quiet time (it drops all peers and can blip LAN DNS), run
  `ifdown wgserver; ifup wgserver` on the router and confirm the `homelab_*`
  rules, the peers and `wg show` are all still correct. That proves a reboot or
  a restart from the UI is safe. Also check that `make router-check` still
  reports no changes afterwards.

- [ ] **9. Remove the hand-made rules.** Once the `homelab_`* rules work, delete
  the old hand-made rules by name, once: `allow_wg_to_palworld`,
   `allow_wg_to_games_subnet` (with the leading space), `allow_admin_access_lan`
  and `allow_admin_access_device`, plus the three empty rules (name them first,
  or delete from the highest index down, since indexes shift). Run `make router-check` again: no changes. Ask one friend to connect as a
  final check, and check that my girlfriend's phone still gets internet and
  `palworld.internal`.
  Nobody's reach should change. Today the two game rules match all of
  `10.0.0.0/24`, but only `tunnel` and `players` depend on them: `admin` already
  reaches the whole LAN (which contains `games` and `.119`), and friends' client
  configs and the lack of any other LAN rule keep them to those two destinations.
  What changes is that the rules are scoped per group instead of to the whole
  tunnel subnet, so a new peer reaches nothing until it's in a group.

- [ ] **10. Hand out configs from the repo.** `make wg-client PEER=friend-2`
  prints a client config (`QR=1` for a QR code, which needs `qrencode`) with the
  peer's private key, the router's public key, the endpoint, `DNS = 10.0.0.1`
  and the `AllowedIPs` for the peer's group (for `players`:
  `10.0.0.1/32, 192.168.8.119/32, 192.168.8.48/29`), rendered by `op inject`
  to the terminal, never to a file (the template with only `op://` references is
  written to `ansible/.ansible/` and removed after). Adding a friend becomes: create the 1Password item, add one
  line to `wg_peers`, `make router`, `make wg-client`.

- [x] **11. Docs.** Done: ADR 0009, README and `docs/bootstrap.md`: what the role
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
- **Editing in the UI** is still possible, but a peer or `homelab_`* rule
changed there is overwritten on the next `make router`. Change those in Git.
- **New games and existing clients.** A new destination inside a range friends
already route (the `games` /29) works for everyone at once. A destination
outside it also needs friends' client configs updated, because their
`AllowedIPs` live on their devices.
- **VM 200:** retiring it (phase 2, step 12) becomes deleting the
`palworld-vm` destination and running `make router`.
- **DNS and DHCP** (AdGuard rewrites like `palworld.internal`, DHCP
reservations) are on the same router and could be managed the same way later.
They're left out to keep this phase small.

## After phase 4

1. [Phase 5](phase-5-renovate.md): dependency update PRs with Renovate. It

   doesn't depend on this phase and can be done before it.
2. Observability (VictoriaMetrics and Grafana), phase 6.
3. Nice to have: off-host backups of the Palworld volume, and Reloader.
