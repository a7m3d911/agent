#!/bin/bash
# Dispatch the next cluster. Fired by spawn.timer at STARTED_AT + 3h.
#
# The rotation is a chain, not a schedule: each box starts exactly one successor
# partway through its own life, so the pair stays staggered and a cold start is
# manual by construction — with nothing running, nothing spawns anything.
#
# Reads /opt/cluster.env (repo, branch) and /etc/spawn.env (token, mode 600).
# Logs to /var/log/spawn.log.

set -o pipefail

log() { echo "[$(date -u '+%F %T')] $*"; }

: "${GITHUB_REPOSITORY:?not set — cannot tell which repo to dispatch}"
: "${SPAWN_TOKEN:?not set — see /etc/spawn.env}"
BRANCH="${GITHUB_REF_NAME:-main}"
WORKFLOW="${SPAWN_WORKFLOW:-server.yml}"
API="https://api.github.com/repos/$GITHUB_REPOSITORY/actions/workflows/$WORKFLOW"

gh_get() {
  curl -sf --max-time 30 \
    -H "Authorization: Bearer $SPAWN_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$1"
}

log "=== spawn check for $GITHUB_REPOSITORY ($WORKFLOW on $BRANCH) ==="

# Don't over-spawn. A box started by hand alongside this one would otherwise
# make three, each of which spawns its own successor — the chain would fan out.
active=0
for status in queued in_progress; do
  n=$(gh_get "$API/runs?status=$status&per_page=100" | jq -r '.total_count // 0')
  [[ "$n" =~ ^[0-9]+$ ]] && active=$((active + n))
done
log "Active runs: $active"

if (( active >= 2 )); then
  log "Already $active clusters alive — not spawning."
  exit 0
fi

for attempt in 1 2 3 4 5; do
  if curl -sf --max-time 30 -X POST \
       -H "Authorization: Bearer $SPAWN_TOKEN" \
       -H "Accept: application/vnd.github+json" \
       -H "X-GitHub-Api-Version: 2022-11-28" \
       "$API/dispatches" -d "{\"ref\":\"$BRANCH\"}"; then
    log "Dispatched successor on $BRANCH"
    exit 0
  fi
  log "Dispatch attempt $attempt failed — retrying in $((attempt * 20))s"
  sleep $((attempt * 20))
done

# Nothing else will notice: no poller, no schedule. The chain ends here unless
# handoff.sh manages to dispatch one itself later.
log "ALERT: could not dispatch a successor after 5 attempts. The rotation chain is broken."
log "Hint: the token needs 'workflow' scope (actions: write) to dispatch."
exit 1
