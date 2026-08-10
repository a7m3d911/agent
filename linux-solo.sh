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
# CONFIG_DEST   : where to place them (default = k3s auto-apply manifests dir)
if [[ -n "$GDRIVE_TOKEN" ]]; then
  GDRIVE_FOLDER="${GDRIVE_FOLDER:-configs}"
  CONFIG_DEST="${CONFIG_DEST:-/var/lib/rancher/k3s/server/manifests}"

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
  sudo mkdir -p "$CONFIG_DEST"
  # copy (add/update only) — never deletes local files, so a Drive hiccup can't
  # empty the manifests dir and tear the app down. Use 'sync' for a strict mirror.
  sudo rclone copy "gdrive:$GDRIVE_FOLDER" "$CONFIG_DEST"

  echo "### Schedule config sync every 5 min (root cron) ###"
  ( sudo crontab -l 2>/dev/null; \
    echo "*/5 * * * * rclone copy gdrive:$GDRIVE_FOLDER $CONFIG_DEST >/dev/null 2>&1" ) \
    | sudo crontab -

  echo "Configs synced to $CONFIG_DEST (refreshes every 5 min, k3s auto-applies)"
else
  echo "### GDRIVE_TOKEN not set — skipping Google Drive config sync ###"
fi

echo "### Install k3s (standalone single-node cluster) ###"

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

echo ""
echo "=========================================="
echo "Standalone cluster ready: $LINUX_MACHINE_NAME"
echo "On this box:        sudo k3s kubectl get nodes"
echo "As $LINUX_USERNAME:  kubectl get nodes"
echo "Remote kubeconfig:  /home/$LINUX_USERNAME/.kube/config (API at https://$TAILSCALE_IP:6443)"
echo "Manifests:          ${CONFIG_DEST:-<no gdrive sync>} (auto-applied by k3s)"
echo "=========================================="
