# Phase 4b: Internal DNS names as code

Goal: the `.internal` names (`palworld.internal`, `homelab.internal` and the
rest) are defined in this repo and applied by the router role from phase 4.
"Done" means adding or changing a name is one line in
`ansible/inventory/group_vars/router.yml` plus `make router`, the hand-made
AdGuard rewrites are gone, and a factory reset of the router gets every name
back from the repo plus two AdGuard settings typed in once.

Today the names are rewrites typed into the AdGuard Home UI, listed in
`docs/bootstrap.md` (Network) so they can be typed in again after a reset.
Phase 4 left them manual because AdGuard's API sits behind GL.iNet's login and
its `config.yaml` is rewritten by both AdGuard and GL.iNet. In this phase the
names move to dnsmasq, which the role can manage with `uci`, and AdGuard is set
once to forward `.internal` lookups to it.

This phase builds on phase 4's role and doesn't depend on phase 5.

## How DNS works on the router

Recorded on 2026-11-09, read-only over SSH, and from a test name (step 1).

- **AdGuard answers clients.** GL.iNet's "AdGuard Home handle client requests"
switch is on (`adguardhome.config.dns_enabled='1'`). With it on,
`/etc/firewall.dns_order` adds an nftables rule (`table inet dns_table`, chain
`adg_redirect`) that redirects every DNS query sent to the router from
`br-lan` and `wgserver` to AdGuard Home 0.107.73 on port 3053. AdGuard asks
its upstreams (`8.8.8.8`, `9.9.9.9`) directly; it doesn't go through dnsmasq.
- **dnsmasq answers only the router itself.** dnsmasq 2.92 still listens on
port 53 (`127.0.0.1`, `192.168.8.1`, `10.0.0.1`), but clients' queries never
reach it because of the redirect. It forwards what it can't answer to
`127.0.0.1#3053` (`dhcp.@dnsmasq[0].server`, with `noresolv='1'`). The
redirect applies only to packets arriving on those interfaces, so the router's
own queries to `127.0.0.1:53` do reach dnsmasq.
- **A test name proved both.** A `dhcp` `domain` section for
`dnstest.internal` was written to `/tmp/hosts/dhcp.cfg01411c` and loaded.
`nslookup dnstest.internal 127.0.0.1` on the router answered `192.168.8.48`,
while `dig dnstest.internal @192.168.8.1` from the Mac got NXDOMAIN from
AdGuard. A `domain` section is a name and address that dnsmasq serves from
that hosts file; GL.iNet uses two for `console.gl-inet.com`.
- **AdGuard's current settings.** The rewrites, in
`/etc/AdGuardHome/config.yaml` under `filtering.rewrites`: the seven names in
`docs/bootstrap.md`, plus `palworld.fun` pointing at `192.168.8.48`, which
isn't documented anywhere. `use_private_ptr_resolvers: true` with
`local_ptr_upstreams` empty, which means reverse lookups for private addresses
go to the router's system resolvers, i.e. the ISP's servers in
`/tmp/resolv.conf`. Rewrites take priority over upstreams in AdGuard.
- **Nothing else rewrites dnsmasq's server list** as far as the shell scripts
show: `/usr/bin/rtp2.sh` and GL.iNet's Tailscale RPC only read it. GL.iNet's
compiled UI code can't be checked this way, so the role checks the list on
every run.
- **WireGuard restarts keep** `dhcp` **sections.** GL.iNet's WireGuard start and
stop scripts run `server_set_dhcp` (`/lib/functions/vpn_server_func.sh`). It
sets only `localservice` on the dnsmasq section, then runs `uci commit dhcp`
and reloads dnsmasq. It never deletes sections, so `homelab_*` sections
survive a tunnel restart. Like the firewall in phase 4, though, it commits
anything left staged in `dhcp`.
- The `dhcp` config also holds two DHCP reservations (`host` sections, tagged
`homelab` and `palworld`). They are out of scope here.

## Decisions

| Topic | Decision | Why |
| --- | --- | --- |
| Where the names live | dnsmasq, as `dhcp` `domain` sections | dnsmasq is configured through `uci` like the rest of the role. AdGuard's own rewrites would need its API (behind GL.iNet's login) or edits to a YAML file two programs rewrite |
| How clients reach them | AdGuard keeps answering clients and forwards `.internal` to dnsmasq: one Upstream DNS servers line, `[/internal/]127.0.0.1:53`, set once by hand | Keeps AdGuard's per-device query log, statistics and settings, which turning off "handle client requests" would lose (every query would come from `127.0.0.1`). It's one stable line, not one per name |
| Reverse lookups | AdGuard's Private reverse DNS servers set to `127.0.0.1:53`, once by hand | dnsmasq answers PTR for its hosts entries, so AdGuard's query log and clients see `palworld.internal` instead of a bare address. Today those lookups go to the ISP |
| The other AdGuard settings | Untouched | Fallback servers are used only when every upstream fails, and bootstrap servers only look up the hostnames of encrypted upstreams. Neither sends a domain somewhere else |
| Loops | dnsmasq answers every `.internal` name itself and never forwards one: the role adds `/internal/` to dnsmasq's `server` list (`server=/internal/` is dnsmasq for "local only") | Without it, a name that isn't defined goes AdGuard to dnsmasq to AdGuard until it times out, instead of a quick NXDOMAIN |
| How a name is written | One named section per name, `dhcp.homelab_dns_<name>` (dots and dashes become `_`), with `name` and `ip` | Named sections give ownership by prefix, as with `homelab_*` firewall rules. dnsmasq's `address` list is the alternative, but it lives on GL.iNet's anonymous dnsmasq section next to values the role doesn't own |
| What the repo owns | `dhcp` sections named `homelab_dns_*`, and the one `/internal/` value in dnsmasq's `server` list | GL.iNet's `domain` sections, the rest of the dnsmasq section and the DHCP reservations stay as they are. Removed names are deleted, as removed rules are |
| AdGuard's config | Read, never written: the role fails if the upstream line is missing, and warns about rewrites that shadow a repo name | A reset or a UI change that drops the line is caught on the next run, without the role owning a file AdGuard and GL.iNet rewrite |
| Names allowed | Only `*.internal` | AdGuard forwards only `.internal` to dnsmasq, so a name anywhere else in `dns_records` would never be answered |
| The list of names | Written in `group_vars/router.yml`, not derived from the OpenTofu inventory | The router role uses its own inventory and must work when OpenTofu or the cluster doesn't (`homelab.internal` is what OpenTofu needs to reach Proxmox). Seven names don't need generating |
| A DNS server elsewhere | No. The router answers every name itself | A server in the cluster or on a VM would go down with what it serves, and `homelab.internal` has to work before the cluster exists. If k8s_gateway is added later (see the README), dnsmasq forwards one subzone such as `k8s.internal` to it with `server=/k8s.internal/<ip>`, which is more specific than `/internal/` |
| Applying | In the same script and run as phase 4, with `dhcp` added to what is compared, backed up and rolled back. dnsmasq is reloaded only when `dhcp` changed | One `make router-check` diff and one rollback timer for everything the role owns. A firewall-only change shouldn't blip DNS |

## What changes in the repo

| Path | Change |
| --- | --- |
| `ansible/inventory/group_vars/router.yml` | New `dns_records` list |
| `ansible/roles/router/templates/uci.batch.j2` | One `domain` section per record |
| `ansible/roles/router/files/apply.sh` | `dhcp` in the preconditions, staging, comparison, backup and rollback; the `/internal/` server entry; the AdGuard config check; delete stale `homelab_dns_*` sections; reload dnsmasq when `dhcp` changed; check every name resolves |
| `ansible/roles/router/tasks/validate.yml` | Checks for `dns_records` |
| `ansible/roles/router/tasks/main.yml` | Task names mention DNS; a check from your machine through AdGuard after an apply |
| `docs/adr/0010-dns-names-in-dnsmasq.md` | New: the decisions above. Add it to `docs/adr/README.md` |
| `docs/bootstrap.md`, `README.md` | The names table moves to `router.yml`; recovery is the two AdGuard settings plus `make router` |
| `docs/plans/phase-4-router-as-code.md` | The "DNS and DHCP stay manual" note points here |

## Part 1: Prove it by hand

- [x] **1. Try one test name.** Before writing any code, confirm the whole path
  (client, AdGuard, dnsmasq) from both the LAN and the tunnel. The test section
  `dhcp.homelab_dns_dnstest_internal` (`dnstest.internal` to `192.168.8.48`)
  is already on the router from the first attempt; check with
  `ssh router 'uci show dhcp.homelab_dns_dnstest_internal'`.
  First stop loops: make dnsmasq answer `.internal` itself, so it never sends
  one back to AdGuard. Do this before the AdGuard change below.
  ```zsh
  ssh router 'uci changes dhcp'      # must print nothing
  ssh router "uci add_list dhcp.@dnsmasq[0].server='/internal/' && uci commit dhcp && /etc/init.d/dnsmasq reload"
  ssh router 'uci get dhcp.@dnsmasq[0].server'   # 127.0.0.1#3053 /internal/
  ```
  Then in the AdGuard Home UI (opened from the GL.iNet admin UI), Settings,
  DNS settings:
  - Upstream DNS servers: add a line `[/internal/]127.0.0.1:53` below the
  existing ones, and leave those as they are.
  - Private reverse DNS servers: `127.0.0.1:53`. Keep "Use private reverse DNS
  resolvers" ticked.
  - Apply each section. AdGuard's "Test upstreams" button should pass.
  Nothing changes for the existing names yet: their rewrites still win. From
  your Mac on the LAN, and again from an admin peer over WireGuard (off Wi-Fi,
  against `10.0.0.1`):
  ```zsh
  dig +short dnstest.internal @192.168.8.1                       # 192.168.8.48
  dig AAAA dnstest.internal @192.168.8.1 | grep status           # NOERROR
  dig nosuch.internal @192.168.8.1 | grep -e status -e 'Query time'   # NXDOMAIN, a few ms
  dig +short -x 192.168.8.48 @192.168.8.1                        # dnstest.internal.
  dig +short palworld.internal @192.168.8.1                      # still 192.168.8.48
  ```
  Results, from the LAN: `dnstest.internal` answered `192.168.8.48`, the AAAA
  query was `NOERROR` with no answer (dnsmasq has `filter-AAAA`, so the records
  stay IPv4 only), `nosuch.internal` was `NXDOMAIN` in 15 ms, the reverse lookup
  returned `dnstest.internal`, and `palworld.internal` stayed `192.168.8.48`.
  Then remove the test name and keep everything else:
  `ssh router 'uci delete dhcp.homelab_dns_dnstest_internal && uci commit dhcp && /etc/init.d/dnsmasq reload'`.

- [x] **2. Decide on** `palworld.fun`**.** Delete it in step 7. `.fun` is a real
  public top-level domain, so the rewrite hides the real `palworld.fun` for
  everyone on the LAN and the tunnel, and it can't move to `dns_records`
  because only `.internal` reaches dnsmasq. Nothing uses it; friends join with
  `palworld.internal`.

## Part 2: Write it

- [x] **3. Add the records to the variables.** Done. In
  `ansible/inventory/group_vars/router.yml`:
  ```yaml
  # Names dnsmasq on the router answers. AdGuard answers clients and forwards
  # *.internal to dnsmasq (its upstream line [/internal/]127.0.0.1:53, set by
  # hand; the role checks it's there). homelab.internal is what OpenTofu uses
  # to reach Proxmox, so it must keep working before the cluster exists.
  dns_records:
    - { name: router.internal,       ip: 192.168.8.1 }
    - { name: homelab.internal,      ip: 192.168.8.150 }
    - { name: k3s-cp-1.internal,     ip: 192.168.8.11 }
    - { name: k3s-worker-1.internal, ip: 192.168.8.12 }
    - { name: k3s-worker-2.internal, ip: 192.168.8.13 }
    - { name: palworld.internal,     ip: 192.168.8.48 }
    - { name: argocd.internal,       ip: 192.168.8.57 }
  ```
  These are the addresses AdGuard answers today, so no answer changes.

- [x] **4. Validate them.** Done. In `tasks/validate.yml`:
  - Each `name` matches `^[a-z0-9]+(-[a-z0-9]+)*(\.[a-z0-9]+(-[a-z0-9]+)*)*\.internal$`,
  and each `ip` is an IPv4 address.
  - Names are unique, and so are their section names after dots and dashes
  become `_` (`a-b.internal` and `a.b.internal` would both be
  `homelab_dns_a_b_internal`).
  - An empty or missing `dns_records` is allowed and means "no names".

- [x] **5. Render and apply them.** Done. Step 1's AAAA query was `NOERROR`, so
  there is no IPv6 entry. In `templates/uci.batch.j2`, per record:
  ```
  set dhcp.homelab_dns_<name>=domain
  set dhcp.homelab_dns_<name>.name='<name>'
  set dhcp.homelab_dns_<name>.ip='<ip>'
  ```
  In `files/apply.sh`:
  - Preconditions: no uncommitted changes in `dhcp` (add it to the existing
  loop). Fail if `/etc/AdGuardHome/config.yaml` has no
  `[/internal/]127.0.0.1:53` line, with a message saying where to add it in
  the AdGuard UI: without it no client sees the names. Warn, without
  failing, if Private reverse DNS servers isn't `127.0.0.1:53`, and list any
  AdGuard rewrite whose domain is in `dns_records`, since it overrides the
  repo. Also fail if `dhcp.@dnsmasq[0].port` is set to anything but `53`.
  - Staging: copy `/etc/config/dhcp` with the others, and pick
  `DESIRED_DNS` out of the static batch with the `=domain$` lines, as
  `DESIRED_RULES` is with `=rule$`.
  - `build_batch`: delete and re-add each desired `homelab_dns_*` section, and
  delete any `homelab_dns_*` section that isn't desired, the same two loops
  as for rules. If `uci get dhcp.@dnsmasq[0].server` lacks `/internal/`,
  `add_list` it; never touch the list's other values. End with `commit dhcp`.
  - Comparison: add `dhcp` to the configs compared. Remember which configs
  changed, not only whether anything did.
  - Backup and rollback: save `/etc/config/dhcp` in `/tmp/homelab-rollback/`
  too, and have `restore.sh` revert, copy it back and run
  `/etc/init.d/dnsmasq reload`.
  - Apply: after the firewall reload, run `/etc/init.d/dnsmasq reload` only if
  `dhcp` changed; roll back if it fails.
  - Verify: for each desired record, `nslookup <name> 127.0.0.1` must return
  its `ip`. Retry for a few seconds first, since dnsmasq restarts in the
  background after a reload. Roll back on a mismatch. This checks dnsmasq;
  the router's BusyBox `nslookup` can't ask AdGuard on port 3053.
  In `tasks/main.yml`, rename the task to "Plan and apply the WireGuard peers,
  firewall rules and DNS names", and after it add a task on your machine that
  runs `dig +short <name> @192.168.8.1` for each record. It runs after every
  apply, and in `--check` only when nothing is pending, since a name the dry
  run would add isn't on the router yet.
  That goes through AdGuard, the path clients use. A mismatch fails the run
  but doesn't roll back: it means AdGuard's settings or a rewrite are wrong,
  not the router config.

## Part 3: Switch over

- [x] **6. Dry run, then apply.** `make router-check` must show only seven `+`
  groups of `dhcp.homelab_dns_*` lines (three lines per name) and nothing for
  `wireguard_server` or `firewall`. It also warns about the seven `.internal`
  rewrites that still exist (`palworld.fun` isn't one of the repo's names, so
  it isn't warned about); that's expected. The dry run on 2026-11-09 did
  exactly that, and changed nothing. Then `make router`. The names keep
  answering from the rewrites, so nothing visible changes yet.

- [x] **7. Remove the AdGuard rewrites.** In the AdGuard Home UI, under Filters,
  DNS rewrites, delete the seven `.internal` ones and `palworld.fun`. Then check:
  - `dig +short <name> @192.168.8.1` for every name, from the LAN, and against
  `10.0.0.1` from an admin peer over WireGuard,
  - `palworld.internal` resolves for a `players` peer (the test phone),
  - AdGuard's query log shows the names answered by upstream `127.0.0.1:53`,
  - `make plan` works (it needs `homelab.internal`), and so does
  `ssh k3s-cp-1.internal true`,
  - `make router-check` says nothing to change and no longer warns.

- [x] **8. Prove a tunnel restart keeps them.** At a quiet time, run
  `ssh router 'ifdown wgserver; ifup wgserver'` (it drops all peers for a few
  seconds and reloads dnsmasq), then check that `make router-check` reports no
  changes and the names still resolve. This is the case where GL.iNet's
  `server_set_dhcp` commits `dhcp`.

- [x] **9. Docs.** Done: ADR 0010 with the decisions above. In `docs/bootstrap.md`
  (Network), replace the table of names with a pointer to `dns_records` in
  `router.yml`. For a router reset: set the two AdGuard settings from step 1
  (Upstream DNS servers line, Private reverse DNS servers), then
  `make router`, which adds the names and the `/internal/` entry and refuses
  to run until the upstream line is there. Keep the note that
  `homelab.internal` is the one name code needs. Update the README's network
  section the same way, and the "DNS and DHCP" note in
  `phase-4-router-as-code.md`.

## Rolling back

Within 5 minutes of an apply, the timer restores `dhcp` with the other files and
reloads dnsmasq. After that, type the AdGuard rewrites back in from the table in
git history (`docs/bootstrap.md` before step 9). They take effect at once,
because rewrites win over the forwarding line. To undo the whole phase, also
delete the `[/internal/]` upstream line and the private reverse DNS setting in
AdGuard, then remove `/internal/` from dnsmasq's `server` list and the
`homelab_dns_*` sections.

## Notes

- **Adding a name** is one line in `dns_records` and `make router`. For a new
MetalLB address, take it from the pool table in `README.md`.
- **The AdGuard UI** can still add rewrites, and one for a `.internal` name
overrides the repo, because rewrites win over upstreams. `make router-check`
lists any such rewrite. Keep every `.internal` name in the repo so there is
one place to look.
- **"Handle client requests"** must stay on. If it's turned off, clients reach
dnsmasq first, which still answers `.internal` itself and forwards the rest
to AdGuard, so the names keep working, but AdGuard's log then shows every
query as coming from `127.0.0.1`.
- **Firmware upgrades** keep `/etc/config` and AdGuard's config as a rule. After
one, `make router-check` shows whether the `/internal/` entry or the
upstream line went missing.
- **DHCP reservations** (the two `host` sections) could be managed the same
way later, as `homelab_host_*` sections keyed by MAC address. They stay
manual for now, as in phase 4.
