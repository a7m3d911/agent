#linux-solo.sh LINUX_USER_PASSWORD TAILSCALE_AUTH_KEY LINUX_USERNAME LINUX_MACHINE_NAME [GDRIVE_TOKEN] [GDRIVE_FOLDER] [CONFIG_DEST]
#!/bin/bash
#
# Provisions a fresh Ubuntu/Debian box as a STANDALONE single-node k3s cluster
# (control-plane + worker) reachable over Tailscale, then pulls all manifests
# from Google Drive so the cluster deploys itself.
#
# Difference vs linux-ser.sh: this box never joins another cluster — it IS the
# cluster. Runner VMs die every ~6h, so instead of nodes leaving/rejoining one
# control-plane, each VM stands up its own full copy of the app and the tunnel
# fans traffic across whichever copies are alive.

### Create login user with sudo ###

sudo useradd -m $LINUX_USERNAME
sudo adduser $LINUX_USERNAME sudo
echo "$LINUX_USERNAME:$LINUX_USER_PASSWORD" | sudo chpasswd
sed -i 's/\/bin\/sh/\/bin\/bash/g' /etc/passwd
sudo hostname $LINUX_MACHINE_NAME

### Validate required inputs ###

if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then
  echo "Please set 'TAILSCALE_AUTH_KEY'"
  exit 2
fi

if [[ -z "$LINUX_USER_PASSWORD" ]]; then
  echo "Please set 'LINUX_USER_PASSWORD' for user: $USER"
  exit 3
fi

echo "### Install Tailscale ###"

curl -fsSL https://tailscale.com/install.sh | sh

echo "### Update user: $USER password ###"
echo -e "$LINUX_USER_PASSWORD\n$LINUX_USER_PASSWORD" | sudo passwd "$USER"

echo "### Start Tailscale with SSH enabled ###"

sudo tailscale up --authkey="$TAILSCALE_AUTH_KEY" --ssh --hostname="$LINUX_MACHINE_NAME" --advertise-exit-node

sleep 5
TAILSCALE_IP=$(tailscale ip -4)

if [[ -n "$TAILSCALE_IP" ]]; then
  echo ""
  echo "=========================================="
  echo "Tailscale IP: $TAILSCALE_IP"
  echo "To connect: ssh $USER@$TAILSCALE_IP"
  echo "or connect with: ssh $USER@$LINUX_MACHINE_NAME"
  echo "=========================================="
else
  echo "Failed to start Tailscale"
  exit 4
fi

# NFS client — required so pods can mount NFS-backed PersistentVolumes.
# Without it kubelet's mount fails with "you might need a /sbin/mount.<type> helper program".
echo "### Install NFS client (nfs-common) ###"
sudo apt-get update && sudo apt-get install -y nfs-common

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

  echo "### Install rclone ###"
  curl -fsSL https://rclone.org/install.sh | sudo bash

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
# the server URL changes. Only the CA keypairs + service.key are carried over —
# the node-specific serving certs are left to regenerate for this box's IP.
# GDRIVE_TLS : Drive folder holding the CA (default "k3s-tls")
K3S_TLS_DIR=/var/lib/rancher/k3s/server/tls
CA_FILTER=(--include "*-ca.crt" --include "*-ca.key" --include "service.key")

if [[ -n "$GDRIVE_TOKEN" ]]; then
  GDRIVE_TLS="${GDRIVE_TLS:-k3s-tls}"
  echo "### Restore cluster CA: gdrive:$GDRIVE_TLS -> $K3S_TLS_DIR ###"
  sudo mkdir -p "$K3S_TLS_DIR"
  sudo rclone copy "gdrive:$GDRIVE_TLS" "$K3S_TLS_DIR" "${CA_FILTER[@]}"
  if [[ -f "$K3S_TLS_DIR/server-ca.crt" ]]; then
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
# --tls-san so kubectl works over Tailscale from other machines.
# --node-ip / --flannel-iface pin cluster traffic to tailscale0, not the public NIC.
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --node-name "$LINUX_MACHINE_NAME" \
  --node-ip "$TAILSCALE_IP" \
  --flannel-iface tailscale0 \
  --tls-san "$LINUX_MACHINE_NAME" \
  --tls-san "$TAILSCALE_IP"

# First boot only in practice: rclone copy skips files Drive already has, so
# later boots re-upload nothing and the CA stays whatever the first box minted.
if [[ -n "$GDRIVE_TOKEN" ]]; then
  echo "### Back up cluster CA -> gdrive:$GDRIVE_TLS ###"
  sudo rclone copy "$K3S_TLS_DIR" "gdrive:$GDRIVE_TLS" "${CA_FILTER[@]}"
fi

echo "### Wait for k3s node to become Ready ###"
until sudo k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; do
  echo "waiting for k3s..."
  sleep 3
done

# Make kubeconfig usable by the created login user (kubectl reads ~/.kube/config).
sudo mkdir -p /home/$LINUX_USERNAME/.kube
sudo cp /etc/rancher/k3s/k3s.yaml /home/$LINUX_USERNAME/.kube/config
sudo sed -i "s/127.0.0.1/$TAILSCALE_IP/g" /home/$LINUX_USERNAME/.kube/config
sudo chown -R $LINUX_USERNAME:$LINUX_USERNAME /home/$LINUX_USERNAME/.kube
sudo ln -sf /usr/local/bin/kubectl /usr/local/bin/k 2>/dev/null || true

echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

### Run the one-shot bootstrap from Drive ###
#
# init.sh does the things the manifests dir can't: kustomize overlays, secrets
# built from CI credentials, third-party operator installs. It runs ONCE per box
# (each VM is a brand-new empty cluster, so "once" is per boot, not ever), unlike
# the *.yaml above which the 5-min cron keeps reconciling.
# Needs from the CI job: GHCR_USER, GHCR_PAT, DOPPLER_TOKEN.
if [[ -f "$CONFIG_DEST/init.sh" ]]; then
  # init.sh reads the Doppler token via the CLI, so install and seed it first.
  if [[ -n "$DOPPLER_TOKEN" ]]; then
    echo "### Install Doppler CLI ###"
    curl -sLf --retry 3 https://cli.doppler.com/install.sh | sudo sh
    sudo doppler configure set token "$DOPPLER_TOKEN" --scope /
  else
    echo "WARNING: DOPPLER_TOKEN unset — init.sh will create an empty doppler-token-secret"
  fi

  echo "### Run init.sh from $CONFIG_DEST ###"
  # cd first: init.sh applies relative paths like ./apps/app-accounts/dev
  ( cd "$CONFIG_DEST" && sudo env \
      KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
      GHCR_USER="$GHCR_USER" \
      GHCR_PAT="$GHCR_PAT" \
      DOPPLER_TOKEN="$DOPPLER_TOKEN" \
      bash init.sh ) 2>&1 | tee /var/log/init-sh.log
  echo "init.sh finished (exit ${PIPESTATUS[0]}) — full log at /var/log/init-sh.log"
else
  echo "### No init.sh in $CONFIG_DEST — skipping bootstrap ###"
fi

echo ""
echo "=========================================="
echo "Standalone cluster ready: $LINUX_MACHINE_NAME"
echo "On this box:        sudo k3s kubectl get nodes"
echo "As $LINUX_USERNAME:  kubectl get nodes"
echo "Remote kubeconfig:  /home/$LINUX_USERNAME/.kube/config (API at https://$TAILSCALE_IP:6443)"
echo "Configs:            ${CONFIG_DEST:-<no gdrive sync>} (top-level *.yaml auto-applied by k3s)"
echo "=========================================="
