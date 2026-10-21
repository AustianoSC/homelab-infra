# 0005. MetalLB instead of k3s' servicelb

Status: Accepted (2026-10)

## Context

Game servers need UDP and TCP `LoadBalancer` Services with fixed LAN
addresses that friends can be allowed to reach over WireGuard. k3s' built-in
`servicelb` instead exposes a Service on the node's own IP, so a Service's
address would depend on whichever node it landed on.

## Decision

Disable `servicelb` and run MetalLB in layer 2 mode with two pools:
`games` (`192.168.8.48/29`) and `general` (`192.168.8.56/29`). Services pin an
address with the `metallb.io/loadBalancerIPs` annotation.

## Consequences

- Each game server has a stable address, so the router firewall rule and
  friends' `AllowedIPs` name the `games` block once. Adding a game needs no
  change to either.
- Both pools sit below the router's DHCP range, which starts at
  `192.168.8.100`.
- `autoAssign: false` on `games` only stops automatic assignment. A Service
  that names the pool, or pins an address in it, still gets one, so the
  guarantee is a convention, not enforcement.
- The `frr-k8s` component is disabled in the chart values because only L2 is
  used and it adds around 190MB of images.
- Layer 2 mode sends all of a Service's traffic through one node at a time.
  That is fine at this scale.
