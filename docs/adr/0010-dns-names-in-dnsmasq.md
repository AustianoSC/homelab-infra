# 0010. Internal DNS names in dnsmasq, with AdGuard forwarding to it

Status: Accepted (2026-11). Built in phase 4b; see
[the plan](../plans/phase-4b-router-dns.md). Extends
[ADR 0009](0009-router-config-as-code.md).

## Context

The `.internal` names (`homelab.internal`, `palworld.internal` and the rest)
were rewrites typed into AdGuard Home's UI. Phase 4 left them there: AdGuard's
API sits behind GL.iNet's login, and both AdGuard and GL.iNet rewrite its
`config.yaml`, so owning that file costs more than a handful of names.

dnsmasq is the router's other DNS server, and the router role already manages
it through `uci`. It can't simply be put in front of AdGuard. GL.iNet's
"AdGuard Home handle client requests" switch is on, and with it on a firewall
rule redirects every DNS query from the LAN and from WireGuard to AdGuard on
port 3053. dnsmasq answers only the router's own lookups.

## Decision

The names are `dns_records` in `ansible/inventory/group_vars/router.yml`. The
router role writes each as a `dhcp` `domain` section named `homelab_dns_*`,
which dnsmasq serves, and adds `/internal/` to dnsmasq's `server` list so
dnsmasq answers the whole zone itself and never forwards one.

AdGuard keeps answering clients. Two settings, made once by hand, send the
zone to dnsmasq:

- Upstream DNS servers gets `[/internal/]127.0.0.1:53`.
- Private reverse DNS servers is `127.0.0.1:53`, so IP-to-name lookups return
  the names instead of going to the ISP.

The role reads AdGuard's config and never writes it. It refuses to run when
the upstream line is missing, and it warns when an AdGuard rewrite names
something in `dns_records`, because a rewrite wins over the forwarding line.
Only `*.internal` names are allowed. `homelab.internal` is written in the
variables rather than taken from the OpenTofu inventory, because that name is
what OpenTofu needs to reach Proxmox, including before the cluster exists.

`dhcp` joins the configs the role compares, backs up and rolls back, in the
same run as the peers and firewall rules. dnsmasq is reloaded only when
`dhcp` changed.

## Alternatives

- **AdGuard rewrites, managed through its API or `config.yaml`.** One place for
  the names, but the API needs GL.iNet's login and the file is rewritten by
  two programs.
- **Turn off "handle client requests",** so clients reach dnsmasq first and it
  forwards everything else to AdGuard. Fully code, and it keeps working, but
  AdGuard then sees every query as coming from `127.0.0.1` and its per-device
  log and statistics go away.
- **A DNS server in the cluster or on a VM.** It would be down exactly when
  `homelab.internal` is needed to rebuild. Names generated from Kubernetes
  Services can come later, for one subzone such as `k8s.internal`, forwarded
  by dnsmasq to something like
  [k8s_gateway](https://github.com/k8s-gateway/k8s_gateway). The static names
  stay on the router.

## Consequences

- Adding or changing a name is one line in `dns_records` and `make router`.
- A rewrite added in AdGuard for a `.internal` name overrides the repo until
  it's deleted. `make router-check` lists any that do.
- "Handle client requests" stays on. Turning it off doesn't break the names,
  but AdGuard's log stops showing which device asked.
- After a factory reset, set the two AdGuard lines above and run `make router`.
  The role adds the names and the `/internal/` entry, and refuses to run until
  the upstream line is there. DHCP reservations stay manual.
- A firmware upgrade keeps `/etc/config` and AdGuard's config as a rule. After
  one, `make router-check` shows whether the `/internal/` entry or the upstream
  line went missing.
