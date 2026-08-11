#!/bin/bash
# Cluster discovery over the Google Drive folder we already sync.
#
# Runner VMs have no fixed address and no shared control-plane, so they need
# somewhere to find each other. Drive is already authenticated on every box, so
# it doubles as the registry instead of standing up a coordination service.
#
#   state/members/<id>.json   {id, vpn_ip, api, started_at, expires_at}
#   state/primary.json        {id, vpn_ip, since}
#
# ponytail: no locking. Rotations are 3h apart and only the outgoing primary
# writes primary.json, so there is one writer at a time. Add a lease file if
# rotations ever get close enough to race.

GDRIVE_STATE="${GDRIVE_STATE:-state}"

# The rclone config lives in /root — provisioning runs as the CI user with sudo,
# the handoff timer runs as root. sudo covers both.
_rclone() { if [[ $EUID -eq 0 ]]; then rclone "$@"; else sudo rclone "$@"; fi; }

_state_cat()  { _rclone cat "gdrive:$GDRIVE_STATE/$1" 2>/dev/null; }
_state_put()  { _rclone rcat "gdrive:$GDRIVE_STATE/$1" 2>/dev/null; }   # reads stdin

now() { date +%s; }

# state_register <id> <vpn_ip> <ttl_seconds>
state_register() {
  local id="$1" ip="$2" ttl="$3" start
  start=$(now)
  jq -nc --arg id "$id" --arg ip "$ip" \
        --argjson start "$start" --argjson exp "$((start + ttl))" \
        '{id:$id, vpn_ip:$ip, api:("https://"+$ip+":6443"), started_at:$start, expires_at:$exp}' \
    | _state_put "members/$id.json"
}

state_deregister() { _rclone deletefile "gdrive:$GDRIVE_STATE/members/$1.json" 2>/dev/null || true; }

# state_live_members [exclude_id] — one JSON object per line, soonest to expire last.
state_live_members() {
  local exclude="${1:-}" n f
  n=$(now)
  for f in $(_rclone lsf "gdrive:$GDRIVE_STATE/members/" 2>/dev/null); do
    _state_cat "members/$f" | jq -c --argjson n "$n" --arg ex "$exclude" \
      'select(.expires_at > $n) | select(.id != $ex)'
  done | jq -sc 'sort_by(-.expires_at) | .[]'
}

# state_successor <self_id> — the live member with the most life left. Empty if alone.
state_successor() { state_live_members "$1" | head -1; }

state_primary()     { _state_cat primary.json; }
state_set_primary() { jq -nc --arg id "$1" --arg ip "$2" --argjson t "$(now)" \
                        '{id:$id, vpn_ip:$ip, since:$t}' | _state_put primary.json; }

# cluster_reachable <ip> — a stale primary.json must not make a lone box wait
# forever for a peer that is already dead, so we probe the API before trusting it.
cluster_reachable() {
  curl -sk --max-time 5 "https://$1:6443/livez" >/dev/null 2>&1
}

# decide_role <self_id> -> prints "bootstrap" or "standby <primary_ip>"
# Bootstrap means: initdb (or recover from R2 if a backup exists) and take the
# primary role. Standby means: replicate from the named primary and wait.
decide_role() {
  local self="$1" p ip
  p=$(state_primary)
  [[ -z "$p" ]] && { echo bootstrap; return; }

  ip=$(jq -r '.vpn_ip // empty' <<<"$p")
  [[ "$(jq -r '.id // empty' <<<"$p")" == "$self" ]] && { echo bootstrap; return; }

  if [[ -n "$ip" ]] && cluster_reachable "$ip"; then
    echo "standby $ip"
  else
    echo bootstrap
  fi
}
