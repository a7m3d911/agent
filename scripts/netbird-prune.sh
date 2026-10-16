#!/usr/bin/env bash
# Delete orphaned NetBird peers: offline, in group agent-runners, last seen > 1h ago.
# Dry run by default; pass --delete to actually delete.
#   NETBIRD_TOKEN=nbp_... bash scripts/netbird-prune.sh [--delete]
set -euo pipefail
API="${NETBIRD_API:-https://netbird.marbit.dev}"
GROUP="${GROUP:-agent-runners}"
: "${NETBIRD_TOKEN:?set NETBIRD_TOKEN (personal access token)}"
cutoff=$(( $(date +%s) - ${MIN_AGE_SECONDS:-3600} ))

curl -fsS --max-time 30 -H "Authorization: Token $NETBIRD_TOKEN" "$API/api/peers" |
  jq -r --arg g "$GROUP" --argjson c "$cutoff" '
    .[] | select(.connected == false)
        | select(any(.groups[]?; .name == $g))
        | select((.last_seen | sub("\\.[0-9]+"; "") | sub("Z$"; "Z") | fromdateiso8601) < $c)
        | "\(.id)\t\(.name)\t\(.last_seen)"' > /tmp/netbird-orphans.tsv

n=$(wc -l < /tmp/netbird-orphans.tsv | tr -d ' ')
column -t -s $'\t' /tmp/netbird-orphans.tsv || true
echo "$n orphaned peer(s) in group '$GROUP'"

[[ "${1:-}" == "--delete" ]] || { echo "dry run — rerun with --delete"; exit 0; }
while IFS=$'\t' read -r id name _; do
  curl -fsS --max-time 30 -X DELETE -H "Authorization: Token $NETBIRD_TOKEN" "$API/api/peers/$id" \
    && echo "deleted $name" || echo "FAILED $name"
done < /tmp/netbird-orphans.tsv
