#!/bin/bash
# Hand the primary role to a live peer, then let this VM die.
#
# Fired by handoff.timer 15 minutes before GitHub kills the runner. Because the
# deadline is known in advance, every step here is a planned, ordered operation
# instead of a failure the peer has to detect. Order matters and is the whole
# point: stop taking traffic -> stop writing -> flush WAL -> confirm the standby
# is caught up -> promote it -> repoint both clusters.
#
# Reads /opt/cluster.env (systemd EnvironmentFile). Logs to /var/log/handoff.log.

set -o pipefail

source /opt/runner-scripts/discovery.sh
source /opt/runner-scripts/dns.sh

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
DB_NS="${DB_NS:-db}"
PG_CLUSTER="${PG_CLUSTER:-postgresql}"
CATCHUP_TIMEOUT="${CATCHUP_TIMEOUT:-180}"

log() { echo "[$(date -u '+%F %T')] $*"; }

# kubeconfig for a peer's API. Works only because the k3s CA is pinned in Drive:
# same CA and same client cert everywhere, so only the address differs.
peer_kubeconfig() {
  local ip="$1" out="/tmp/peer-$ip.kubeconfig"
  sed "s|server: https://[^:]*:6443|server: https://$ip:6443|" \
    /etc/rancher/k3s/k3s.yaml > "$out"
  echo "$out"
}

kpeer() { local kc="$1"; shift; kubectl --kubeconfig "$kc" "$@"; }

pg_primary_pod() {
  kubectl -n "$DB_NS" get pod -l "cnpg.io/cluster=$PG_CLUSTER,cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
  || kubectl -n "$DB_NS" get pod -l "cnpg.io/cluster=$PG_CLUSTER,role=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

psql_primary() {
  local pod; pod=$(pg_primary_pod)
  [[ -z "$pod" ]] && return 1
  kubectl -n "$DB_NS" exec "$pod" -c postgres -- psql -U postgres -Atc "$1"
}

log "=== handoff starting for $CLUSTER_ID ($VPN_IP), role=$ROLE ==="

### 0. Are we actually the primary? ###

primary_id=$(state_primary | jq -r '.id // empty')
if [[ "$primary_id" != "$CLUSTER_ID" ]]; then
  log "Not the primary (registry says '$primary_id') — draining traffic only."
  kubectl -n cf scale deploy cloudflared-deployment --replicas=0 2>/dev/null || true
  state_deregister "$CLUSTER_ID"
  log "=== done (standby exit) ==="
  exit 0
fi

### 1. Pick a successor ###

# Walk candidates newest-first until one actually answers. A hard-killed VM never
# deregisters, so the registry always contains corpses — taking the top entry on
# faith would hand the primary role to a box that no longer exists.
find_successor() {
  local candidate cand_ip
  while read -r candidate; do
    [[ -z "$candidate" ]] && continue
    cand_ip=$(jq -r .vpn_ip <<<"$candidate")
    if cluster_reachable "$cand_ip"; then
      echo "$candidate"
      return 0
    fi
    log "Skipping $(jq -r .id <<<"$candidate") — registered but unreachable (dead VM?)"
    state_deregister "$(jq -r .id <<<"$candidate")"
  done < <(state_live_members "$CLUSTER_ID")
  return 1
}

successor=$(find_successor) || successor=""

# Backstop for a broken chain: if the spawn timer failed 3h ago there is no peer
# at all. Starting one now is late — it may not finish provisioning before this
# VM is killed — but it is the difference between a gap and an outage that lasts
# until someone notices.
if [[ -z "$successor" && -x /opt/runner-scripts/spawn-successor.sh ]]; then
  log "No peer found — chain looks broken. Dispatching one now."
  set -a; [[ -f /etc/spawn.env ]] && source /etc/spawn.env; set +a
  /opt/runner-scripts/spawn-successor.sh || log "WARN: emergency dispatch failed"

  for _ in $(seq 40); do   # ~10 min: provisioning plus the restore from R2
    sleep 15
    successor=$(find_successor) && break || successor=""
  done
  [[ -n "$successor" ]] && log "Emergency successor came up: $(jq -r .id <<<"$successor")"
fi

if [[ -z "$successor" ]]; then
  # Draining now would take the site down with nothing to take over. Better to
  # keep serving until GitHub kills us: the WAL is already archived to R2, so the
  # next box recovers from there with only in-flight writes lost.
  log "ALERT: no live peer to hand over to. Staying up until killed; next boot recovers from R2."
  exit 1
fi

succ_id=$(jq -r .id <<<"$successor")
succ_ip=$(jq -r .vpn_ip <<<"$successor")
kc=$(peer_kubeconfig "$succ_ip")
log "Successor: $succ_id ($succ_ip)"

# Reachable is not the same as ready to take over: a peer whose database is still
# restoring would accept the promotion and serve nothing.
if ! kpeer "$kc" -n "$DB_NS" get cluster "$PG_CLUSTER" \
     -o jsonpath='{.status.readyInstances}' 2>/dev/null | grep -q '[1-9]'; then
  log "ALERT: successor $succ_id has no ready Postgres instance. Aborting handoff."
  exit 1
fi

### 2. Stop taking web traffic HERE ###
#
# cloudflared deregisters cleanly on SIGTERM, so Cloudflare stops routing to this
# cluster while it is still healthy. The peer's tunnel connections keep serving —
# this is the step that makes the rotation invisible to users.
log "Draining tunnel connections..."
kubectl -n cf scale deploy cloudflared-deployment --replicas=0
kubectl -n cf rollout status deploy/cloudflared-deployment --timeout=60s 2>/dev/null || true

### 3. Stop writing ###

# Demote ourselves FIRST so the storage sidecars stop uploading before the
# successor is promoted. Two clusters pushing one R2 prefix corrupt each other.
log "Demoting local storage sidecars to standby..."
for ns in app-9router; do
  kubectl -n "$ns" create configmap cluster-role --from-literal=ROLE=standby \
    --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1 || true
done

log "Scaling down local app workloads..."
# The 9router pod's sidecar does a final R2 push on SIGTERM, so this scale-down
# is also what flushes its data — hence the wait before promoting anyone.
kubectl -n app-9router scale deploy 9router --replicas=0 2>/dev/null || true
kubectl -n apps scale deploy --all --replicas=0 2>/dev/null || true
kubectl -n app-9router wait --for=delete pod -l app=9router --timeout=90s 2>/dev/null || true
sleep 5

### 4. Flush everything the standby still needs ###

log "Checkpoint + WAL switch..."
psql_primary "CHECKPOINT;" >/dev/null 2>&1 || log "WARN: checkpoint failed"
psql_primary "SELECT pg_switch_wal();" >/dev/null 2>&1 || log "WARN: pg_switch_wal failed"

### 5. Wait for the standby to be byte-for-byte current ###

log "Waiting for standby to catch up (timeout ${CATCHUP_TIMEOUT}s)..."
caught_up=0
for ((i = 0; i < CATCHUP_TIMEOUT; i += 2)); do
  n=$(psql_primary "SELECT count(*) FROM pg_stat_replication WHERE replay_lsn = sent_lsn;" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )) && { caught_up=1; break; }
  sleep 2
done

if (( caught_up )); then
  log "Standby is current."
else
  # Promoting now would lose whatever has not replayed. The archive still has it,
  # so we let the successor finish from R2 rather than silently dropping writes.
  log "WARN: standby did not confirm catch-up; it must replay the remaining WAL from R2."
fi

### 6. Promote ###
#
# Declarative promotion: clearing replica mode on the Cluster CR is what CNPG
# watches. No cnpg kubectl plugin needed on the box.
log "Promoting $succ_id..."
kpeer "$kc" -n "$DB_NS" patch cluster "$PG_CLUSTER" --type merge \
  -p '{"spec":{"replica":{"enabled":false}}}'

kpeer "$kc" -n "$DB_NS" exec deploy/redis -- redis-cli REPLICAOF NO ONE 2>/dev/null \
  || log "WARN: redis promote failed (no redis deploy?)"

### 7. Repoint the successor at its own now-primary data ###
#
# Apps everywhere address postgresql.db.svc.cluster.local; the Endpoints object
# behind that name is what actually decides which cluster serves it.
log "Flipping service endpoints on $succ_id to local..."
pg_pod_ip=$(kpeer "$kc" -n "$DB_NS" get pod \
  -l "cnpg.io/cluster=$PG_CLUSTER" -o jsonpath='{.items[0].status.podIP}')
redis_pod_ip=$(kpeer "$kc" -n "$DB_NS" get pod -l app=redis -o jsonpath='{.items[0].status.podIP}')

[[ -n "$pg_pod_ip" ]] && kpeer "$kc" -n "$DB_NS" patch endpoints postgresql --type merge \
  -p "{\"subsets\":[{\"addresses\":[{\"ip\":\"$pg_pod_ip\"}],\"ports\":[{\"port\":5432,\"name\":\"postgres\"}]}]}"
[[ -n "$redis_pod_ip" ]] && kpeer "$kc" -n "$DB_NS" patch endpoints redis --type merge \
  -p "{\"subsets\":[{\"addresses\":[{\"ip\":\"$redis_pod_ip\"}],\"ports\":[{\"port\":6379,\"name\":\"redis\"}]}]}"

### 8. Publish the new primary and stand down ###

### 8. Let the successor's storage sidecars start writing ###
#
# Last, and only after our own were demoted and flushed: the R2 prefix has one
# writer at a time. Restarting 9router there also makes it re-pull the data we
# just pushed, so it picks up everything written right up to the drain.
log "Promoting storage sidecars on $succ_id..."
for ns in app-9router; do
  kpeer "$kc" -n "$ns" create configmap cluster-role --from-literal=ROLE=primary \
    --dry-run=client -o yaml 2>/dev/null | kpeer "$kc" apply -f - >/dev/null 2>&1 || true
done
kpeer "$kc" -n app-9router rollout restart deploy/9router 2>/dev/null || true

### 9. Publish the new primary and stand down ###

state_set_primary "$succ_id" "$succ_ip"
# After the promote, not before: until step 6 the successor is a read-only
# replica, and pointing the zone at it early serves reads that cannot write.
dns_point "$succ_ip"
state_deregister "$CLUSTER_ID"
log "=== handoff complete: $succ_id is primary ==="
