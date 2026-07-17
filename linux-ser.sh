#linux-ser.sh LINUX_USER_PASSWORD TAILSCALE_AUTH_KEY LINUX_USERNAME LINUX_MACHINE_NAME [K3S_URL K3S_TOKEN] [GDRIVE_TOKEN] [GDRIVE_FOLDER] [CONFIG_DEST]
#!/bin/bash
#
# Provisions a fresh Ubuntu/Debian box as a single-node Kubernetes server (k3s),
# reachable over Tailscale SSH. Same user/SSH + Tailscale setup as linux-ssh.sh,
# but without the GitHub runner / workflow-agent bits.

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

# NFS client — required on every node so pods can mount NFS-backed PersistentVolumes.
# Without it kubelet's mount fails with "you might need a /sbin/mount.<type> helper program".
echo "### Install NFS client (nfs-common) ###"
sudo apt-get update && sudo apt-get install -y nfs-common

# Mode: if K3S_URL + K3S_TOKEN are set, join an existing cluster as a worker node.
#       Otherwise install as a standalone single-node server (control-plane + worker).
#   K3S_URL   : https://<server-tailscale-ip>:6443
#   K3S_TOKEN : contents of /var/lib/rancher/k3s/server/node-token on the server
if [[ -n "$K3S_URL" && -n "$K3S_TOKEN" ]]; then
  echo "### Join k3s cluster as worker node -> $K3S_URL ###"

  # K3S_URL/K3S_TOKEN in the env make the installer run 'k3s agent' (no control-plane).
  curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -s - \
    --node-name "$LINUX_MACHINE_NAME"

  echo ""
  echo "=========================================="
  echo "Joined as worker node: $LINUX_MACHINE_NAME"
  echo "Verify from the SERVER: kubectl get nodes"
  echo "Agent status here:      sudo systemctl status k3s-agent"
  echo "=========================================="
else
  echo "### Install k3s (single-node Kubernetes server) ###"

  # Single binary = control-plane + worker + containerd + flannel CNI + local-path storage.
  # --write-kubeconfig-mode 644 so the created user can read kubeconfig without sudo.
  # --tls-san $LINUX_MACHINE_NAME / $TAILSCALE_IP so kubectl works over Tailscale from other machines.
  curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644 \
    --node-name "$LINUX_MACHINE_NAME" \
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

  echo ""
  echo "=========================================="
  echo "k3s ready. On this box:  sudo k3s kubectl get nodes"
  echo "As $LINUX_USERNAME:       kubectl get nodes"
  echo "Remote kubeconfig:       /home/$LINUX_USERNAME/.kube/config (API at https://$TAILSCALE_IP:6443)"
  echo "Join a worker: re-run this script on another box with K3S_URL=https://$TAILSCALE_IP:6443"
  echo "               and K3S_TOKEN from /var/lib/rancher/k3s/server/node-token"
  echo "=========================================="

  echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
fi

### Sync configurations from Google Drive (optional) ###

# Provisioning is unattended, so we can't run rclone's interactive OAuth here.
# Instead authorize ONCE on your laptop and pass the token in via GDRIVE_TOKEN:
#     rclone authorize "drive"   # copy the JSON token it prints
# GDRIVE_FOLDER : Drive path to pull (default "configs")
# CONFIG_DEST   : where to place them locally (default /home/$LINUX_USERNAME/configs)
if [[ -n "$GDRIVE_TOKEN" ]]; then
  GDRIVE_FOLDER="${GDRIVE_FOLDER:-configs}"
  CONFIG_DEST="${CONFIG_DEST:-/home/$LINUX_USERNAME/configs}"

  echo "### Install rclone ###"
  curl -fsSL https://rclone.org/install.sh | sudo bash

  echo "### Write rclone config for user: $LINUX_USERNAME ###"
  sudo -u "$LINUX_USERNAME" mkdir -p "/home/$LINUX_USERNAME/.config/rclone"
  sudo tee "/home/$LINUX_USERNAME/.config/rclone/rclone.conf" > /dev/null <<CONF
[gdrive]
type = drive
scope = drive
token = $GDRIVE_TOKEN
CONF
  sudo chown -R "$LINUX_USERNAME:$LINUX_USERNAME" "/home/$LINUX_USERNAME/.config"
  sudo chmod 600 "/home/$LINUX_USERNAME/.config/rclone/rclone.conf"

  echo "### Initial sync: gdrive:$GDRIVE_FOLDER -> $CONFIG_DEST ###"
  sudo -u "$LINUX_USERNAME" mkdir -p "$CONFIG_DEST"
  # copy (add/update only) — never deletes local files. Swap to 'sync' for a strict mirror.
  sudo -u "$LINUX_USERNAME" rclone copy "gdrive:$GDRIVE_FOLDER" "$CONFIG_DEST"

  echo "### Schedule config sync every 5 min (cron) ###"
  ( sudo -u "$LINUX_USERNAME" crontab -l 2>/dev/null; \
    echo "*/5 * * * * rclone copy gdrive:$GDRIVE_FOLDER $CONFIG_DEST >/dev/null 2>&1" ) \
    | sudo -u "$LINUX_USERNAME" crontab -

  echo "Configs synced to $CONFIG_DEST (refreshes every 5 min)"
else
  echo "### GDRIVE_TOKEN not set — skipping Google Drive config sync ###"
fi