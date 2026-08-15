#!/bin/bash
# Point the NetBird DNS zone at whichever box is currently primary.
#
# Peer FQDNs are useless as a stable address: CLUSTER_ID carries the run number
# and NetBird suffixes the octets on collision, so the same cluster is
# agent-runner-50-167-112 this rotation and something else the next. These A
# records are the stable name — everything that resolves *.marbit.group goes
# through them, so they have to be rewritten every time the primary moves.
#
# Called twice in the rotation's life:
#   linux-solo.sh — when a bootstrap box claims primary
#   handoff.sh    — when the successor is promoted
#
# Needs NETBIRD_TOKEN (PAT) and NETBIRD_DNS_ZONE. Both absent is not an error:
# a cluster with no DNS wiring should still come up.

NETBIRD_API="${NETBIRD_API:-https://netbird.marbit.dev}"

# dns_point <ip> — repoint every A record in the zone at <ip>.
dns_point() {
  local ip="$1" api url records id name content rc=0

  if [[ -z "$NETBIRD_TOKEN" || -z "$NETBIRD_DNS_ZONE" ]]; then
    echo "dns: NETBIRD_TOKEN/NETBIRD_DNS_ZONE unset — leaving DNS alone"
    return 0
  fi
  [[ -n "$ip" ]] || { echo "dns: no IP given"; return 1; }

  url="$NETBIRD_API/api/dns/zones/$NETBIRD_DNS_ZONE/records"
  records=$(curl -fsS --max-time 20 -H "Authorization: Token $NETBIRD_TOKEN" "$url") || {
    echo "dns: could not list records at $url"
    return 1
  }

  while read -r r; do
    [[ -n "$r" ]] || continue
    id=$(jq -r '.id' <<<"$r")
    name=$(jq -r '.name' <<<"$r")
    content=$(jq -r '.content' <<<"$r")

    # Skip no-op writes: a rotation where the IP happens to be reused should not
    # churn the zone (and every write is a chance to break a working record).
    if [[ "$content" == "$ip" ]]; then
      echo "dns: $name already $ip"
      continue
    fi

    if curl -fsS --max-time 20 -X PUT \
         -H "Authorization: Token $NETBIRD_TOKEN" \
         -H 'Content-Type: application/json' \
         -d "$(jq -c --arg ip "$ip" '{name, type, ttl, content: $ip}' <<<"$r")" \
         "$url/$id" >/dev/null
    then
      echo "dns: $name $content -> $ip"
    else
      echo "dns: FAILED to update $name ($id)"
      rc=1
    fi
  done < <(jq -c '.[] | select(.type == "A")' <<<"$records")

  return $rc
}
