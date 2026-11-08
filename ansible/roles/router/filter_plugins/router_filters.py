"""Filters for the router role."""

from __future__ import annotations

from ansible.errors import AnsibleFilterError


def wg_allowed_ips(group_name, groups, tunnel_ip):
    """Return what a peer's client config sends into the tunnel.

    GL.iNet's UI stores this string in the peer's ``allowed_ips``, and
    ``make wg-client`` puts the same string in the client config, so the router
    and the config agree.

    A group with ``internet: true`` sends everything through the router.
    Otherwise it is the router's tunnel address (for DNS) plus the address
    range of each of the group's ``to: lan`` destinations, in the order the
    group lists them.
    """
    try:
        group = groups[group_name]
    except KeyError as err:
        raise AnsibleFilterError(f"wg_allowed_ips: no access group named {group_name!r}") from err

    if group.get("internet", False):
        return "0.0.0.0/0"

    networks = [f"{tunnel_ip}/32"]
    for destination in group["destinations"]:
        if destination["to"] != "lan":
            continue
        address = destination["dest_ip"]
        networks.append(address if "/" in address else f"{address}/32")
    return ", ".join(networks)


class FilterModule:
    """Registers the filters with Ansible."""

    def filters(self):
        return {"wg_allowed_ips": wg_allowed_ips}
