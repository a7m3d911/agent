#linux-solo.sh LINUX_USER_PASSWORD LINUX_USERNAME LINUX_MACHINE_NAME [VPN_PROVIDER] [TAILSCALE_AUTH_KEY | NETBIRD_MANAGEMENT_URL NETBIRD_SETUP_KEY] [GDRIVE_TOKEN] [GDRIVE_FOLDER] [CONFIG_DEST]
#!/bin/bash
#
# Provisions a fresh Ubuntu/Debian box as a STANDALONE single-node k3s cluster
# (control-plane + worker) on a VPN mesh, then pulls all manifests from Google
# Drive so the cluster deploys itself.
#
# This box never joins another cluster — it IS the cluster. Runner VMs die every
# ~6h, so instead of nodes leaving and rejoining one control-plane, two clusters
# run staggered: each new box comes up as a STANDBY of the live primary, and the
# outgoing box hands over before it is killed. Continuity comes from four places:
#   - the shared Cloudflare tunnel (both clusters serve the same hostnames)
#   - Postgres streaming replication + WAL archive to R2
#   - Redis replication during the overlap
#   - this script's role handshake, coordinated through Drive
#
# Role for this boot is decided in decide_role() below and written to
# /opt/cluster.env for init.sh and handoff.sh to read.

set -o pipefail

SCRIPT_START=$(date +%s)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# GitHub kills the VM 6h after the job starts. We know that deadline in advance,
# which is the whole reason a *planned* handoff is possible instead of a crash.
JOB_TTL_SECONDS="${JOB_TTL_SECONDS:-21600}"
HANDOFF_LEAD_SECONDS="${HANDOFF_LEAD_SECONDS:-900}"   # start handing over 15m before the kill
# Half the job length: the successor is then exactly 3h behind, so the pair stays
# staggered and there is always one mature cluster and one warm one.
SPAWN_AFTER_SECONDS="${SPAWN_AFTER_SECONDS:-10800}"

### Identity — must be unique, two of these are alive at once ###

CLUSTER_ID="${LINUX_MACHINE_NAME}-${GITHUB_RUN_NUMBER:-$SCRIPT_START}"

### Create login user with sudo ###

sudo useradd -m $LINUX_USERNAME
sudo adduser $LINUX_USERNAME sudo
echo "$LINUX_USERNAME:$LINUX_USER_PASSWORD" | sudo chpasswd
sed -i 's/\/bin\/sh/\/bin\/bash/g' /etc/passwd
sudo hostname "$CLUSTER_ID"

### Validate required inputs ###

if [[ -z "$LINUX_USER_PASSWORD" ]]; then
  echo "Please set 'LINUX_USER_PASSWORD' for user: $USER"
  exit 3
fi

echo "### Install base tooling (jq, nfs-common, rclone) ###"
# jq: discovery.sh parses the Drive registry with it.
# nfs-common: kubelet needs it to mount NFS-backed PVs ("no /sbin/mount.<type>").
# rclone: from apt, NOT rclone.org's curl|bash installer — that download gets
# reset from runner egress often enough to matter, and when it does every Drive
# step below turns into a no-op (no configs, no CA restore, fresh CA, dead
# kubeconfigs). Apt's build is years behind upstream and entirely fine for copy.
sudo apt-get update && sudo apt-get install -y jq nfs-common rclone

echo "### Bring up the VPN mesh (provider: ${VPN_PROVIDER:-tailscale}) ###"

source "$SCRIPT_DIR/scripts/vpn.sh"
source "$SCRIPT_DIR/scripts/discovery.sh"

vpn_install

echo "### Update user: $USER password ###"
echo -e "$LINUX_USER_PASSWORD\n$LINUX_USER_PASSWORD" | sudo passwd "$USER"

vpn_up "$CLUSTER_ID" || exit 4

VPN_IP=$(vpn_ip) || { echo "VPN came up but reported no address"; exit 4; }

echo ""
echo "=========================================="
echo "Cluster ID: $CLUSTER_ID"
echo "Mesh IP:    $VPN_IP  (iface $VPN_IFACE)"
echo "Connect:    ssh $USER@$VPN_IP"
echo "=========================================="

### Sync configurations from Google Drive ###
#
# Runs BEFORE k3s installs: anything in /var/lib/rancher/k3s/server/manifests is
# auto-applied by k3s at startup and re-applied whenever a file changes, so the
# cron below doubles as the deploy loop — no kubectl apply anywhere.
#
# Provisioning is unattended, so we can't run rclone's interactive OAuth here.
# Authorize ONCE on your laptop and pass the token in via GDRIVE_TOKEN:
#     rclone authorize "drive"   # copy the JSON token it prints
# GDRIVE_FOLDER : Drive path to pull (default "configs")
# CONFIG_DEST   : full local copy of that folder (default /opt/configs)
#
# Two destinations, because the Drive folder is no longer just manifests:
#   $CONFIG_DEST     — whole tree (init.sh, apps/ kustomize overlays, yaml)
#   $MANIFEST_DIR    — ONLY the top-level *.yaml, which k3s auto-applies.
# apps/ must stay out of the manifests dir: k3s walks it recursively and would
# apply the overlay's raw files un-kustomized (and choke on kustomization.yaml).
MANIFEST_DIR=/var/lib/rancher/k3s/server/manifests

if [[ -n "$GDRIVE_TOKEN" ]]; then
  GDRIVE_FOLDER="${GDRIVE_FOLDER:-configs}"
  CONFIG_DEST="${CONFIG_DEST:-/opt/configs}"

  # Stop here rather than three steps later: without rclone the config sync and
  # the CA restore both quietly do nothing, and the CA one corrupts the pin.
  command -v rclone >/dev/null || { echo "FATAL: rclone missing — apt-get install failed"; exit 6; }

  echo "### Write rclone config (root — manifests dir is root-owned) ###"
  sudo mkdir -p /root/.config/rclone
  sudo tee /root/.config/rclone/rclone.conf > /dev/null <<CONF
[gdrive]
type = drive
scope = drive
token = $GDRIVE_TOKEN
CONF
  sudo chmod 600 /root/.config/rclone/rclone.conf

  echo "### Initial sync: gdrive:$GDRIVE_FOLDER -> $CONFIG_DEST ###"
  sudo mkdir -p "$CONFIG_DEST" "$MANIFEST_DIR"
  # copy (add/update only) — never deletes local files, so a Drive hiccup can't
  # empty the manifests dir and tear the app down. Use 'sync' for a strict mirror.
  sudo rclone copy "gdrive:$GDRIVE_FOLDER" "$CONFIG_DEST"
  sudo rclone copy "$CONFIG_DEST" "$MANIFEST_DIR" --max-depth 1 --include "*.yaml"

  echo "### Schedule config sync every 5 min (root cron) ###"
  ( sudo crontab -l 2>/dev/null; \
    echo "*/5 * * * * rclone copy gdrive:$GDRIVE_FOLDER $CONFIG_DEST >/dev/null 2>&1 && rclone copy $CONFIG_DEST $MANIFEST_DIR --max-depth 1 --include '*.yaml' >/dev/null 2>&1" ) \
    | sudo crontab -

  echo "Configs synced to $CONFIG_DEST (refreshes every 5 min; *.yaml auto-applied by k3s)"
else
  echo "### GDRIVE_TOKEN not set — skipping Google Drive config sync ###"
fi

### Pin the cluster CA so the kubeconfig never changes ###
#
# A fresh k3s install mints a brand-new CA and admin client cert, so every VM
# would hand you a different kubeconfig. Keep the CA in Drive instead: the first
# boot generates and uploads it, every later boot restores it before k3s starts.
# Same CA => a kubeconfig saved once stays valid against every future box; only
# the server URL changes. It is also what lets the outgoing box drive the
# incoming box's API during handoff. Only the CA keypairs + service.key are
# carried over — node-specific serving certs regenerate for this box's IP.
# GDRIVE_TLS : Drive folder holding the CA (default "k3s-tls")
K3S_TLS_DIR=/var/lib/rancher/k3s/server/tls
CA_FILTER=(--include "*-ca.crt" --include "*-ca.key" --include "service.key")

CA_RESTORED=0

if [[ -n "$GDRIVE_TOKEN" ]]; then
  GDRIVE_TLS="${GDRIVE_TLS:-k3s-tls}"
  echo "### Restore cluster CA: gdrive:$GDRIVE_TLS -> $K3S_TLS_DIR ###"
  sudo mkdir -p "$K3S_TLS_DIR"
  # Abort rather than continue: a transient Drive error here is indistinguishable
  # from "first boot ever", and guessing wrong means minting a fresh CA and
  # publishing it over the good one — which invalidates every kubeconfig ever
  # saved, with no way back.
  if ! sudo rclone copy "gdrive:$GDRIVE_TLS" "$K3S_TLS_DIR" "${CA_FILTER[@]}"; then
    echo "FATAL: could not read gdrive:$GDRIVE_TLS — refusing to mint a new CA"
    exit 6
  fi
  if [[ -f "$K3S_TLS_DIR/server-ca.crt" ]]; then
    CA_RESTORED=1
    echo "Reusing existing CA — your saved kubeconfig still works"
  else
    echo "No CA in Drive yet — k3s will generate one and we upload it below"
  fi
fi

echo "### Install k3s (standalone single-node cluster) ###"

# get.k3s.io switches to agent mode purely from the ENV. If K3S_URL/K3S_TOKEN
# leak in from the CI job, we'd silently install an agent joining someone else's
# cluster instead of a server. This script is standalone-only, so drop them.
unset K3S_URL K3S_TOKEN

# Single binary = control-plane + worker + containerd + flannel CNI + local-path storage.
# --write-kubeconfig-mode 644 so the created user can read kubeconfig without sudo.
# --tls-san so kubectl works over the mesh from other machines (and from the peer
# cluster during handoff).
# --node-ip / --flannel-iface pin cluster traffic to the mesh, not the public NIC.
k3s_install() {
  curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644 \
    --node-name "$CLUSTER_ID" \
    --node-ip "$VPN_IP" \
    --flannel-iface "$VPN_IFACE" \
    --tls-san "$CLUSTER_ID" \
    --tls-san "$VPN_IP"
}

# GitHub throttles anonymous release downloads per runner IP (REFUSED_STREAM /
# 503), and the installer's "Download failed" exits 0 through the pipe — so a
# failed install is indistinguishable from a successful one unless we check.
# Silently continuing left the readiness loop below spinning forever.
for attempt in 1 2 3 4 5; do
  k3s_install
  systemctl is-active --quiet k3s && break
  echo "k3s install attempt $attempt failed (GitHub throttling?) — retrying in $((attempt * 15))s"
  sleep $((attempt * 15))
done

if ! systemctl is-active --quiet k3s; then
  echo "FATAL: k3s did not install after 5 attempts — see the installer output above"
  exit 5
fi

# Publish ONLY when this box actually minted the CA — i.e. the first boot ever.
# `rclone copy` does not protect us here: it skips on matching size AND modtime,
# and two different k3s CAs are byte-identical in size (same EC P-256 template),
# so a fresh one always looks "newer" and silently overwrites the pinned CA.
if [[ -n "$GDRIVE_TOKEN" && $CA_RESTORED -eq 0 ]]; then
  echo "### First CA ever — publishing to gdrive:$GDRIVE_TLS ###"
  sudo rclone copy "$K3S_TLS_DIR" "gdrive:$GDRIVE_TLS" "${CA_FILTER[@]}"
elif [[ -n "$GDRIVE_TOKEN" ]]; then
  echo "### CA came from Drive — not re-uploading ###"
fi

echo "### Wait for k3s node to become Ready ###"
# Bounded: an unbounded `until` here is how a broken install turns into a job
# that prints "waiting for k3s..." for six hours and never fails.
for _ in $(seq 200); do
  sudo k3s kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break
  echo "waiting for k3s..."
  sleep 3
done

if ! sudo k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; then
  echo "FATAL: k3s installed but the node never became Ready"
  sudo journalctl -u k3s --no-pager -n 40
  exit 5
fi

# Make kubeconfig usable by the created login user (kubectl reads ~/.kube/config).
sudo mkdir -p /home/$LINUX_USERNAME/.kube
sudo cp /etc/rancher/k3s/k3s.yaml /home/$LINUX_USERNAME/.kube/config
sudo sed -i "s/127.0.0.1/$VPN_IP/g" /home/$LINUX_USERNAME/.kube/config
sudo chown -R $LINUX_USERNAME:$LINUX_USERNAME /home/$LINUX_USERNAME/.kube
sudo ln -sf /usr/local/bin/kubectl /usr/local/bin/k 2>/dev/null || true

echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

### Decide this box's role and announce it ###
#
# Registration happens only now, once the API actually answers — a peer that
# finds us in the registry must be able to reach us immediately.
ROLE=bootstrap
PRIMARY_IP=""
SOURCE_ID=""

if [[ -n "$GDRIVE_TOKEN" ]]; then
  EXPIRES_AT=$((SCRIPT_START + JOB_TTL_SECONDS))

  # Read the outgoing primary BEFORE we overwrite the record: its id is the
  # archive path the database restores from. Empty only on the very first boot
  # ever — anything else means there is data in R2 and initdb would be data loss.
  SOURCE_ID=$(state_primary | jq -r '.id // empty')

  read -r ROLE PRIMARY_IP <<<"$(decide_role "$CLUSTER_ID")"
  # TTL is what's LEFT, not the full job length — provisioning already burned
  # a few minutes and peers pick a successor by remaining life.
  state_register "$CLUSTER_ID" "$VPN_IP" "$((EXPIRES_AT - $(date +%s)))"

  if [[ "$ROLE" == "bootstrap" ]]; then
    echo "### Role: BOOTSTRAP — will claim primary once the database is up ###"
  else
    echo "### Role: STANDBY of $PRIMARY_IP — replicating, will take over at handoff ###"
  fi
fi

# NOTE: the primary claim happens AFTER init.sh, not here. Claiming up front
# means a box that dies during provisioning still names itself in primary.json,
# and the next box then tries to restore from an R2 archive that box never
# wrote — an unrecoverable wait for a backup that does not exist.

# Everything downstream (init.sh from Drive, handoff.sh from the timer) reads
# this instead of re-deriving the role.
sudo tee /opt/cluster.env > /dev/null <<ENV
CLUSTER_ID=$CLUSTER_ID
VPN_PROVIDER=${VPN_PROVIDER:-tailscale}
VPN_IFACE=$VPN_IFACE
VPN_IP=$VPN_IP
ROLE=$ROLE
PRIMARY_IP=$PRIMARY_IP
SOURCE_ID=$SOURCE_ID
STARTED_AT=$SCRIPT_START
EXPIRES_AT=$((SCRIPT_START + JOB_TTL_SECONDS))
CONFIG_DEST=${CONFIG_DEST:-/opt/configs}
GDRIVE_STATE=${GDRIVE_STATE:-state}
KUBECONFIG=/etc/rancher/k3s/k3s.yaml
GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-}
GITHUB_REF_NAME=${GITHUB_REF_NAME:-}
ENV

# The dispatch token, kept out of cluster.env because that file is world-readable
# and this one is not.
sudo tee /etc/spawn.env > /dev/null <<ENV
SPAWN_TOKEN=$GH_TOKEN
ENV
sudo chmod 600 /etc/spawn.env

# Keep the helper scripts on the box: handoff.sh runs hours after the CI
# checkout is gone.
sudo mkdir -p /opt/runner-scripts
sudo cp "$SCRIPT_DIR"/scripts/*.sh /opt/runner-scripts/
sudo chmod +x /opt/runner-scripts/*.sh

### Run the one-shot bootstrap from Drive ###
#
# init.sh does the things the manifests dir can't: kustomize overlays, secrets
# built from CI credentials, third-party operator installs. It runs ONCE per box
# (each VM is a brand-new empty cluster, so "once" is per boot, not ever), unlike
# the *.yaml above which the 5-min cron keeps reconciling.
# Needs from the CI job: GHCR_USER, GHCR_PAT, DOPPLER_TOKEN, R2_*.
if [[ -f "$CONFIG_DEST/init.sh" ]]; then
  # init.sh reads the Doppler token via the CLI, so install and seed it first.
  if [[ -n "$DOPPLER_TOKEN" ]]; then
    echo "### Install Doppler CLI ###"
    curl -sLf --retry 3 https://cli.doppler.com/install.sh | sudo sh
    sudo doppler configure set token "$DOPPLER_TOKEN" --scope /
  else
    echo "WARNING: DOPPLER_TOKEN unset — init.sh will create an empty doppler-token-secret"
  fi

  echo "### Run init.sh from $CONFIG_DEST (role: $ROLE) ###"
  # cd first: init.sh applies relative paths like ./apps/app-accounts/dev
  ( cd "$CONFIG_DEST" && sudo env \
      KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
      CLUSTER_ID="$CLUSTER_ID" \
      VPN_IP="$VPN_IP" \
      ROLE="$ROLE" \
      PRIMARY_IP="$PRIMARY_IP" \
      SOURCE_ID="$SOURCE_ID" \
      GDRIVE_STATE="${GDRIVE_STATE:-state}" \
      GHCR_USER="$GHCR_USER" \
      GHCR_PAT="$GHCR_PAT" \
      DOPPLER_TOKEN="$DOPPLER_TOKEN" \
      R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
      R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
      R2_BUCKET="$R2_BUCKET" \
      R2_ENDPOINT="$R2_ENDPOINT" \
      bash init.sh ) 2>&1 | tee /var/log/init-sh.log
  INIT_RC=${PIPESTATUS[0]}
  echo "init.sh finished (exit $INIT_RC) — full log at /var/log/init-sh.log"

  # Only now, with a database actually serving, is it safe to tell the next box
  # to restore from this one's archive.
  if [[ "$ROLE" == "bootstrap" && -n "$GDRIVE_TOKEN" ]]; then
    if [[ $INIT_RC -eq 0 ]]; then
      state_set_primary "$CLUSTER_ID" "$VPN_IP"
      echo "### Claimed primary: $CLUSTER_ID ###"
    else
      echo "### init.sh failed — NOT claiming primary, leaving the record untouched ###"
    fi
  fi
else
  echo "### No init.sh in $CONFIG_DEST — skipping bootstrap ###"
fi

### Schedule the handoff before GitHub kills this VM ###
#
# A systemd timer rather than cron: cron's finest granularity is a minute and we
# want a one-shot at an exact wall-clock moment, computed from the job deadline.
if [[ -n "$GDRIVE_TOKEN" ]]; then
  HANDOFF_AT=$((SCRIPT_START + JOB_TTL_SECONDS - HANDOFF_LEAD_SECONDS))
  HANDOFF_STAMP=$(date -u -d "@$HANDOFF_AT" '+%Y-%m-%d %H:%M:%S UTC')

  sudo tee /etc/systemd/system/handoff.service > /dev/null <<UNIT
[Unit]
Description=Drain this cluster and hand the primary role to a live peer

[Service]
Type=oneshot
EnvironmentFile=/opt/cluster.env
ExecStart=/opt/runner-scripts/handoff.sh
StandardOutput=append:/var/log/handoff.log
StandardError=append:/var/log/handoff.log
UNIT

  sudo tee /etc/systemd/system/handoff.timer > /dev/null <<UNIT
[Unit]
Description=Fire the handoff 15 minutes before GitHub kills this runner

[Timer]
OnCalendar=$HANDOFF_STAMP
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT

  sudo systemctl daemon-reload
  sudo systemctl enable --now handoff.timer
  echo "### Handoff scheduled for $HANDOFF_STAMP (log: /var/log/handoff.log) ###"
fi

### Schedule the successor ###
#
# The rotation is a chain: this box starts the next one partway through its own
# life. Nothing polls and nothing is on a cron, so with no cluster running there
# is nothing to start anything — a cold start is manual by construction, which
# is the intent.
if [[ -n "$GITHUB_REPOSITORY" ]]; then
  SPAWN_AT=$((SCRIPT_START + SPAWN_AFTER_SECONDS))
  SPAWN_STAMP=$(date -u -d "@$SPAWN_AT" '+%Y-%m-%d %H:%M:%S UTC')

  sudo tee /etc/systemd/system/spawn.service > /dev/null <<UNIT
[Unit]
Description=Dispatch the next cluster in the rotation

[Service]
Type=oneshot
EnvironmentFile=/opt/cluster.env
EnvironmentFile=/etc/spawn.env
ExecStart=/opt/runner-scripts/spawn-successor.sh
StandardOutput=append:/var/log/spawn.log
StandardError=append:/var/log/spawn.log
UNIT

  sudo tee /etc/systemd/system/spawn.timer > /dev/null <<UNIT
[Unit]
Description=Start the successor 3h into this cluster's life

[Timer]
OnCalendar=$SPAWN_STAMP
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT

  sudo systemctl daemon-reload
  sudo systemctl enable --now spawn.timer
  echo "### Successor scheduled for $SPAWN_STAMP (log: /var/log/spawn.log) ###"
else
  echo "### GITHUB_REPOSITORY unset — no successor will be spawned ###"
fi

echo ""
echo "=========================================="
echo "Cluster ready: $CLUSTER_ID  (role: $ROLE)"
echo "On this box:        sudo k3s kubectl get nodes"
echo "As $LINUX_USERNAME:  kubectl get nodes"
echo "Remote kubeconfig:  /home/$LINUX_USERNAME/.kube/config (API at https://$VPN_IP:6443)"
echo "Configs:            ${CONFIG_DEST:-<no gdrive sync>} (top-level *.yaml auto-applied by k3s)"
echo "Role/state:         /opt/cluster.env"
echo "=========================================="
