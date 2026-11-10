#!/usr/bin/env bash
# Make a WireGuard key pair for a new peer: the private key goes straight into
# 1Password as wg-peer-<name> (field `password`, the same shape `make wg-client`
# reads), and a ready-to-paste wg_peers line is printed with the public key, the
# next free tunnel address and an unused peer_id.
#
# Usage: scripts/wg-new-peer.sh <name> <group>      (or: make wg-peer PEER=<name> GROUP=<group>)
#
# The private key is never printed, written to a file, or passed as a process
# argument; it moves through a shell variable and pipes only.
# Needs op (signed in), jq and wg (brew install jq wireguard-tools).
set -euo pipefail

vars=ansible/inventory/group_vars/router.yml

die() { echo "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "Usage: $0 <name> <group>"
name=$1
group=$2

for t in op jq wg; do
  command -v "$t" >/dev/null || die "Missing tool: $t (brew install jq wireguard-tools, and the 1Password CLI)"
done
[ -f "$vars" ] || die "Run from the repo root ($vars not found)"

# The name ends up in a 1Password item title and a YAML line.
[[ $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "Name '$name' must be lowercase letters, digits and dashes (a nickname; the repo is public)"

# Groups are the keys directly under wg_access_groups.
groups=$(awk '/^wg_access_groups:/{f=1; next} f && /^[^ #]/{f=0} f && /^  [a-z][a-z0-9_-]*:/{sub(/^  /,""); sub(/:.*/,""); print}' "$vars")
grep -qx "$group" <<<"$groups" || die "Unknown group '$group'. Choose one of: $(tr '\n' ' ' <<<"$groups")"

grep -Eq "name: $name," "$vars" && die "A peer named '$name' is already in $vars"
op item get "wg-peer-$name" --vault homelab >/dev/null 2>&1 && die "1Password item wg-peer-$name already exists"

# Next free tunnel address: one above the highest 10.0.0.N/32 in use.
last=$(grep -Eo 'address: 10\.0\.0\.[0-9]+/32' "$vars" | sed -E 's/.*\.([0-9]+)\/32/\1/' | sort -n | tail -1)
[ -n "$last" ] || die "Found no peer addresses in $vars"
[ "$last" -lt 254 ] || die "No free address left in 10.0.0.0/24"
address="10.0.0.$((last + 1))/32"

# An unused number for the router's section name (peer_<id>); the router makes up its own.
while :; do
  id=$((RANDOM % 9000 + 1000))
  grep -Eq "peer_id: $id," "$vars" || break
done

key=$(wg genkey)
printf '%s\n' "$key" \
  | jq -Rn --arg t "wg-peer-$name" \
      '{title:$t, category:"PASSWORD",
        fields:[{id:"password", label:"password", purpose:"PASSWORD", type:"CONCEALED", value:input}]}' \
  | op item create --vault homelab - >/dev/null
unset key

# Derive the public key from what 1Password stored, which also proves the round trip.
pub=$(op read "op://homelab/wg-peer-$name/password" | wg pubkey)

echo "Created 1Password item wg-peer-$name." >&2
echo "Add this under wg_peers in $vars:" >&2
echo >&2
echo "  - { name: $name, peer_id: $id, group: $group, address: $address, public_key: $pub }"
echo >&2
echo "Then: make router-check && make router && make wg-client PEER=$name" >&2
