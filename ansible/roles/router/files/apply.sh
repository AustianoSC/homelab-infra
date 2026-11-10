#!/bin/sh
# Runs on the router (BusyBox ash, no Python): checks the WireGuard peers,
# firewall rules and internal DNS names against the repo, and applies the
# difference.
#
# This is plain shell. templates/run.sh.j2 puts it after the settings it needs
# (MODE, IFACE, ZONE, SERVER, RESTART, DELAY, ABSENT_IDS) and a desired_batch
# function that prints the `uci batch` lines from templates/uci.batch.j2, and
# Ansible sends the result with `script`. The router has no diff, setsid,
# nohup or comm, so this sticks to what it has: uci, wg, nft, sort, uniq, sed.
#
#   1. Stage the change on copies of the config files and compare the result.
#   2. In plan mode (--check) stop there.
#   3. Otherwise save the old config, arm a timer that restores it, apply the
#      change, reload, verify, and only then disarm the timer.
#
# shellcheck disable=SC2154  # the settings above come from run.sh.j2
set -eu
umask 077

STAGE=/tmp/homelab-stage
RB=/tmp/homelab-rollback
STATIC="$STAGE/static.batch"

fail() { echo "HOMELAB_ERROR: $*" >&2; exit 1; }

# --- Preconditions ----------------------------------------------------------
# With access=DROP, GL.iNet keeps wgserver2lan off, so a peer reaches the LAN
# only through the rules in the batch. ACCEPT would give every peer the LAN.
[ "$(uci -q get "wireguard_server.$SERVER.access" || true)" = DROP ] \
  || fail "wireguard_server.$SERVER.access is not DROP (the UI's allow-access-to-LAN switch is on); turn it off first"
[ "$(uci -q get "firewall.$ZONE.name" || true)" = "$ZONE" ] \
  || fail "no firewall zone named $ZONE; is the WireGuard server set up in the UI?"
for c in wireguard_server firewall dhcp; do
  [ -z "$(uci changes "$c" 2>/dev/null || true)" ] \
    || fail "uncommitted uci changes in $c; commit or revert them first"
done

rm -rf "$STAGE"
mkdir -p "$STAGE/etc" "$STAGE/delta"
trap 'rm -rf "$STAGE"' EXIT
cp /etc/config/wireguard_server /etc/config/firewall /etc/config/dhcp "$STAGE/etc/"

# --- What the repo says should exist ----------------------------------------
desired_batch > "$STATIC"
DESIRED_RULES=$(sed -n 's/^set firewall\.\(homelab_[A-Za-z0-9_]*\)=rule$/\1/p' "$STATIC" | tr '\n' ' ')
DESIRED_PEERS=$(sed -n 's/^set wireguard_server\.peer_\([0-9]*\)=peers$/\1/p' "$STATIC" | tr '\n' ' ')
DESIRED_DNS=$(sed -n 's/^set dhcp\.\(homelab_dns_[A-Za-z0-9_]*\)=domain$/\1/p' "$STATIC" | tr '\n' ' ')

# Clients reach AdGuard first: GL.iNet redirects their queries to it. AdGuard
# must send this zone on to dnsmasq, which is where the names are served. Its
# config is only read, never written.
if [ -n "$DESIRED_DNS" ]; then
  port=$(uci -q get 'dhcp.@dnsmasq[0].port' || true)
  if [ -n "$port" ] && [ "$port" != 53 ]; then
    fail "dnsmasq listens on port $port, not 53, so it would not answer these names"
  fi
  [ -f "$ADGUARD_CONFIG" ] \
    || fail "AdGuard's config $ADGUARD_CONFIG is missing; add the upstream $DNS_UPSTREAM in AdGuard Home (Settings, DNS settings, Upstream DNS servers)"
  grep -qF -e "$DNS_UPSTREAM" "$ADGUARD_CONFIG" \
    || fail "AdGuard has no upstream $DNS_UPSTREAM; add it in AdGuard Home under Settings, DNS settings, Upstream DNS servers. Without it no client sees these names"

  # Private reverse DNS servers, not the upstream line: 127.0.0.1:53 also
  # appears inside the upstream, so this reads only the local_ptr_upstreams list.
  ptr_ok=no
  in_ptr=no
  while IFS= read -r line; do
    case "$line" in
      "  local_ptr_upstreams:"*) in_ptr=yes; continue ;;
    esac
    if [ "$in_ptr" = yes ]; then
      case "$line" in
        "    - "*)
          value=$(printf '%s' "$line" | sed "s/^    - //; s/^[\"']//; s/[\"']\$//")
          if [ "$value" = "$DNS_PTR" ]; then ptr_ok=yes; fi
          ;;
        *) break ;;
      esac
    fi
  done < "$ADGUARD_CONFIG"
  [ "$ptr_ok" = yes ] \
    || echo "HOMELAB_WARN: AdGuard's private reverse DNS servers is not $DNS_PTR, so IP-to-name lookups will not use these names."

  # A rewrite wins over the forwarding line, so one for a repo name hides it.
  names=$(sed -n "s/^set dhcp\.homelab_dns_[A-Za-z0-9_]*\.name='\([^']*\)'$/\1/p" "$STATIC")
  rewrites=$(sed -n "s/^[[:space:]]*- domain:[[:space:]]*[\"']\{0,1\}\([^\"' ]*\)[\"']\{0,1\}$/\1/p" "$ADGUARD_CONFIG")
  for domain in $rewrites; do
    for name in $names; do
      if [ "$domain" = "$name" ]; then
        echo "HOMELAB_WARN: AdGuard rewrite $domain overrides the repo; delete it under Filters, DNS rewrites."
      fi
    done
  done
fi

# Prints the uci batch for the config that $U points at. Rules and DNS names
# owned by the repo are deleted and re-added, so options removed from the
# variables go away; peers are updated in place, so options the repo doesn't
# know (their private key, for one) are never touched.
build_batch() {
  for s in $DESIRED_RULES; do
    if $U -q get "firewall.$s" >/dev/null 2>&1; then echo "delete firewall.$s"; fi
  done
  for s in $($U show firewall | sed -n 's/^firewall\.\(homelab_[A-Za-z0-9_]*\)=rule$/\1/p'); do
    case " $DESIRED_RULES" in
      *" $s "*) ;;
      *) echo "delete firewall.$s" ;;
    esac
  done
  for s in $DESIRED_DNS; do
    if $U -q get "dhcp.$s" >/dev/null 2>&1; then echo "delete dhcp.$s"; fi
  done
  for s in $($U show dhcp | sed -n 's/^dhcp\.\(homelab_dns_[A-Za-z0-9_]*\)=domain$/\1/p'); do
    case " $DESIRED_DNS" in
      *" $s "*) ;;
      *) echo "delete dhcp.$s" ;;
    esac
  done
  for id in $ABSENT_IDS; do
    if $U -q get "wireguard_server.peer_$id" >/dev/null 2>&1; then echo "delete wireguard_server.peer_$id"; fi
  done
  cat "$STATIC"
  for id in $DESIRED_PEERS; do
    if ! $U -q get "wireguard_server.peer_$id" >/dev/null 2>&1; then
      echo "set wireguard_server.peer_$id.presharedkey_enable='0'"
    fi
  done
  # "/internal/" makes dnsmasq answer the zone itself. Without it, a name that
  # isn't defined goes AdGuard -> dnsmasq -> AdGuard until it times out. The
  # list's other values belong to GL.iNet and are left alone.
  if [ -n "$DESIRED_DNS" ]; then
    case " $($U -q get 'dhcp.@dnsmasq[0].server' || true) " in
      *" $DNS_LOCAL "*) ;;
      *) echo "add_list dhcp.@dnsmasq[0].server='$DNS_LOCAL'" ;;
    esac
  fi
  echo "commit wireguard_server"
  echo "commit firewall"
  echo "commit dhcp"
}

# --- Stage the change on copies and see what differs ------------------------
U="uci -c $STAGE/etc -t $STAGE/delta"
build_batch > "$STAGE/stage.batch"
$U batch < "$STAGE/stage.batch" \
  || fail "the generated uci batch doesn't apply to a copy of the config; nothing on the router was changed"

# Sorted, so the order of sections and options doesn't count as a change, and
# without key values, so none can reach the output. The router has no diff, so
# compare with sort and uniq: a line that appears once in "cur new new" is only
# in cur, and one that appears once in "cur cur new" is only in new.
CHANGED=no
DHCP_CHANGED=no
for c in wireguard_server firewall dhcp; do
  uci show "$c" | grep -v -E 'private_key|presharedkey=' | sort > "$STAGE/$c.cur"
  $U show "$c" | grep -v -E 'private_key|presharedkey=' | sort > "$STAGE/$c.new"
  sort "$STAGE/$c.cur" "$STAGE/$c.new" "$STAGE/$c.new" | uniq -u | sed 's/^/- /' > "$STAGE/$c.removed"
  sort "$STAGE/$c.cur" "$STAGE/$c.cur" "$STAGE/$c.new" | uniq -u | sed 's/^/+ /' > "$STAGE/$c.added"
  if [ -s "$STAGE/$c.removed" ] || [ -s "$STAGE/$c.added" ]; then
    CHANGED=yes
    if [ "$c" = dhcp ]; then DHCP_CHANGED=yes; fi
    echo "== $c: - removed from the router, + added"
    cat "$STAGE/$c.removed" "$STAGE/$c.added"
  fi
done

if [ "$CHANGED" = no ]; then
  echo "Nothing to change."
  echo "HOMELAB_RESULT=nochange"
  exit 0
fi
if [ "$MODE" = plan ]; then
  echo "Dry run: nothing was changed on the router."
  echo "HOMELAB_RESULT=changed"
  exit 0
fi

# --- Apply, with a way back -------------------------------------------------
mkdir -p "$RB"
rm -f "$RB"/*
cp /etc/config/wireguard_server /etc/config/network /etc/config/firewall /etc/config/dhcp "$RB/"

cat > "$RB/restore.sh" <<'HOMELAB_RESTORE'
#!/bin/sh
# Puts back the config saved before the last `make router`. A timer on the
# router starts it; run it by hand with: sh /tmp/homelab-rollback/restore.sh
RB=/tmp/homelab-rollback
IFACE="${1:-wgserver}"
RESTART_WG=no
cmp -s "$RB/wireguard_server" /etc/config/wireguard_server || RESTART_WG=yes
uci revert firewall 2>/dev/null
uci revert wireguard_server 2>/dev/null
uci revert dhcp 2>/dev/null
cp "$RB/wireguard_server" "$RB/network" "$RB/firewall" "$RB/dhcp" /etc/config/
/etc/init.d/firewall reload
/etc/init.d/dnsmasq reload
if [ "$RESTART_WG" = yes ]; then
  ifdown "$IFACE"
  ifup "$IFACE"
fi
logger -t homelab-router "restored the config saved before the last apply"
HOMELAB_RESTORE

# The timer runs on the router itself, detached from this SSH session (no
# terminal, all descriptors redirected, HUP ignored), so it still fires if the
# connection to the router is lost. The router has no setsid or nohup.
sh -c 'trap "" HUP; echo $$ > "$1/timer.pid"; sleep "$2"; sh "$1/restore.sh" "$3"' sh "$RB" "$DELAY" "$IFACE" </dev/null >/dev/null 2>&1 &
sleep 1

cancel_timer() {
  if [ -f "$RB/timer.pid" ]; then
    kill "$(cat "$RB/timer.pid")" 2>/dev/null || true
    rm -f "$RB/timer.pid"
  fi
}
rollback_now() {
  echo "HOMELAB_ERROR: $1; putting the previous config back" >&2
  cancel_timer
  sh "$RB/restore.sh" "$IFACE" || true
  exit 1
}
if [ ! -f "$RB/timer.pid" ] || ! kill -0 "$(cat "$RB/timer.pid")" 2>/dev/null; then
  fail "couldn't arm the rollback timer; nothing was changed"
fi

# Public keys as they are now, to find peers that were removed or re-keyed.
U=uci
for id in $DESIRED_PEERS $ABSENT_IDS; do
  echo "$id $(uci -q get "wireguard_server.peer_$id.public_key" || true)"
done > "$STAGE/oldkeys"

build_batch > "$STAGE/real.batch"
uci batch < "$STAGE/real.batch" || rollback_now "uci batch failed"

fw_out=$(/etc/init.d/firewall reload 2>&1) || rollback_now "the firewall didn't reload: $fw_out"
[ -z "$fw_out" ] || echo "firewall: $fw_out"

if [ "$DHCP_CHANGED" = yes ]; then
  dns_out=$(/etc/init.d/dnsmasq reload 2>&1) || rollback_now "dnsmasq didn't reload: $dns_out"
  [ -z "$dns_out" ] || echo "dnsmasq: $dns_out"
fi

if ip link show "$IFACE" >/dev/null 2>&1; then
  if [ "$RESTART" = yes ]; then
    ifdown "$IFACE" || true
    ifup "$IFACE" || rollback_now "the tunnel didn't come back up"
    sleep 5
    /etc/init.d/firewall reload || rollback_now "the firewall didn't reload after the tunnel restart"
  else
    # What `ifup` would build from the config, applied to the running tunnel.
    while read -r id oldkey; do
      newkey=$(uci -q get "wireguard_server.peer_$id.public_key" || true)
      addr=$(uci -q get "wireguard_server.peer_$id.client_ip" || true)
      if [ -n "$oldkey" ] && [ "$oldkey" != "$newkey" ]; then
        wg set "$IFACE" peer "$oldkey" remove || rollback_now "couldn't remove the old key of peer $id"
      fi
      if [ -n "$newkey" ]; then
        wg set "$IFACE" peer "$newkey" allowed-ips "$addr" || rollback_now "couldn't set peer $id"
      fi
    done < "$STAGE/oldkeys"
  fi

  # --- Verify -----------------------------------------------------------------
  live=$(wg show "$IFACE" peers)
  sed -n "s/^set wireguard_server\.peer_\([0-9]*\)\.public_key='\(.*\)'\$/\1 \2/p" "$STATIC" > "$STAGE/newkeys"
  while read -r id key; do
    echo "$live" | grep -qxF "$key" || rollback_now "peer $id is not on $IFACE"
  done < "$STAGE/newkeys"
  for id in $ABSENT_IDS; do
    old=$(sed -n "s/^$id //p" "$STAGE/oldkeys")
    if [ -n "$old" ] && echo "$live" | grep -qxF "$old"; then rollback_now "removed peer $id is still on $IFACE"; fi
  done
  nft_dump=$(nft list table inet fw4 2>/dev/null || true)
  for s in $DESIRED_RULES; do
    echo "$nft_dump" | grep -qF "\"!fw4: $s\"" || rollback_now "rule $s didn't load"
  done
else
  echo "$IFACE is down, so the live tunnel and the loaded rules weren't checked; they apply when it comes up."
fi

# dnsmasq directly, not through AdGuard: the router's nslookup can't ask a
# port other than 53. The task on your machine checks the path clients use.
if [ -n "$DESIRED_DNS" ]; then
  sed -n \
    -e "s/^set dhcp\.homelab_dns_[A-Za-z0-9_]*\.name='\([^']*\)'$/\1/p" \
    -e "s/^set dhcp\.homelab_dns_[A-Za-z0-9_]*\.ip='\([^']*\)'$/\1/p" \
    "$STATIC" > "$STAGE/dns"
  while read -r name && read -r ip; do
    ip_re=$(printf '%s' "$ip" | sed 's/\./\\./g')
    tries=0
    while true; do
      if nslookup "$name" 127.0.0.1 2>/dev/null | grep -qE "Address( 1)?:[[:space:]]*${ip_re}$"; then
        break
      fi
      tries=$((tries + 1))
      if [ "$tries" -ge 10 ]; then
        rollback_now "$name did not resolve to $ip from dnsmasq"
      fi
      sleep 1
    done
  done < "$STAGE/dns"
fi

cancel_timer
echo "Applied. The previous config is kept in $RB until the router reboots."
echo "HOMELAB_RESULT=changed"
