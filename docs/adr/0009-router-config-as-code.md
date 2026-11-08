# 0009. Router WireGuard peers and firewall rules as code, with Ansible and `uci`

Status: Accepted (2026-11). Built in phase 4; see
[the plan](../plans/phase-4-router-as-code.md).

## Context

Friends, family and my own devices reach the homelab over a WireGuard server on
the GL.iNet router. The peers and the firewall rules that limit what each one
can reach were made by hand in the admin UI: six peers, and a handful of rules
that, for example, let anyone in the tunnel reach the game servers. Nothing in
Git said who could reach what, adding a friend meant clicking through the UI,
and a factory reset would have meant remembering all of it.

The router is GL.iNet's firmware on OpenWrt 23.05. It has no Python, so most
Ansible modules can't run on it, and its SSH server (Dropbear) accepts commands
of at most 9000 bytes and has no SFTP server (it does have `dd`, so files can be
piped over the SSH connection).

## Decision

An Ansible role, `router`, run from my machine over LAN SSH, keeps the peers and
firewall rules as `ansible/inventory/group_vars/router.yml` describes them.

- **Only shell on the router.** The role renders one script on my machine,
  `files/apply.sh` (plain shell, checked with `shellcheck`) behind a short
  header of settings and the desired state, and sends it with the `script`
  module over a piped SSH transfer. The script uses `uci`, `wg` and
  `nft`, which are already on the router, and nothing is installed.
- **`uci`, staged first.** The script applies a generated `uci batch` to a copy
  of the config files and compares the result with the live config. That is
  what `make router-check` shows and what keeps a second run at "no changes".
- **A way back.** Before changing anything the script saves the config and
  starts a timer, on the router itself, that restores it after five minutes.
  The timer is cancelled only after the peers and rules have been checked on
  the running router, so a lost connection or a failed check undoes itself.
- **Live peer changes.** Peers are added and removed on the running tunnel with
  `wg set`, next to the `uci` change. GL.iNet's own way, restarting the
  interface, drops every peer and reloads dnsmasq.
- **Groups.** Peers belong to a group (`admin`, `tunnel`, `players`), and each
  group has a list of destinations. One firewall rule per group and destination
  is written, named `homelab_<group>_<destination>`, restricted to that group's
  tunnel addresses. A group with no internet access is also rejected towards
  the WAN. Opening a game to friends is one destination in one place.
- **The repo owns only what it names.** Peers it lists and rules prefixed
  `homelab_`. Everything else GL.iNet or the UI created is left alone, and the
  role refuses to run if the UI's "allow access to the local network" switch
  (`access`) is on, because that would give every peer the whole LAN.
- **Keys.** Each peer's private key is in 1Password
  (`op://homelab/wg-peer-<name>/password`), as is the server's
  (`wg-server`). The router also keeps its own copies, which the role never
  reads, writes or deletes. Applying needs only public keys, so `make router`
  needs no secrets. `make wg-client PEER=<name>` prints a client config, with
  the private key and the public endpoint filled in from 1Password by
  `op inject`, to the terminal only.
- **No preshared keys.** The existing peers don't use them, and turning one on
  means reissuing that peer's config.
- **Nicknames.** The repo is public, so peers are `my-iphone` and `friend-1`,
  not names. Who is who is kept in 1Password.

## Alternatives

- **Keep clicking in the UI.** Nothing to build, but no record, no review and
  no recovery.
- **Python on the router, with the normal modules.** There is room for it, but
  a firmware upgrade can remove packages, and `uci` in a shell script needs nothing
  that can disappear.
- **GL.iNet's API, or copying whole config files.** Both tie the repo to GL.iNet
  internals or to files that hold keys. Sections and options are what `uci`
  documents.
- **A separate WireGuard stack (for example `wg-quick` on a VM).** Moves the
  problem instead of removing it, and the router still has to forward to it.
- **Running it from CI.** Rejected for the same reason as in
  [ADR 0007](0007-pull-based-gitops.md): CI never gets credentials that can
  reach the homelab. The router is pushed to from the LAN.

## Consequences

- Adding a friend, or opening a game, is a change to `group_vars/router.yml`
  and `make router`. Removing a peer is `state: absent` and `make router`.
- A change made in the UI to a listed peer, or to a `homelab_*` rule, is
  overwritten by the next run. Everything else in the UI still works.
- A firmware upgrade can reset the router. `make router-check` shows what
  drifted and `make router` puts it back. After a factory reset, set the
  server's private key back from `wg-server`, and the existing client configs
  keep working.
- A tunnel restart, from the UI or a reboot, runs GL.iNet's own scripts. They
  rewrite only the `wgserver*` sections, so the `homelab_*` rules stay.
- Client `AllowedIPs` live on each device. A new destination inside a range a
  group already routes (the `games` block) works for everyone at once; one
  outside it needs new client configs.
- The role assumes this firmware's names (`wgserver`, `lan`, `wan`,
  `main_server`) and its `wireguard_server` config layout. A GL.iNet release
  that changes them breaks it loudly, because the staged change is checked
  before anything is applied.
