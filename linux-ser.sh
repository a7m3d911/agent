#linux-ser.sh LINUX_USER_PASSWORD LINUX_USERNAME LINUX_MACHINE_NAME [VPN_PROVIDER] [K3S_URL K3S_TOKEN] [GDRIVE_TOKEN] [GDRIVE_FOLDER] [CONFIG_DEST]
#!/bin/bash
#
# Provisions a fresh Ubuntu/Debian box as a k3s node: a worker joining an existing
# cluster when K3S_URL+K3S_TOKEN are set, otherwise a standalone single-node server.
# Reachable over the VPN mesh. No GitHub runner / workflow-agent bits.
#
# The mesh is whichever scripts/vpn.sh selects (VPN_PROVIDER=netbird|tailscale,
# default netbird). Its keys are that provider's:
#   netbird   : NETBIRD_MANAGEMENT_URL, NETBIRD_SETUP_KEY
#   tailscale : TAILSCALE_AUTH_KEY

### Create login user with sudo ###

sudo useradd -m $LINUX_USERNAME
sudo adduser $LINUX_USERNAME sudo
echo "$LINUX_USERNAME:$LINUX_USER_PASSWORD" | sudo chpasswd
sed -i 's/\/bin\/sh/\/bin\/bash/g' /etc/passwd
sudo hostname $LINUX_MACHINE_NAME

### Validate required inputs ###

if [[ -z "$LINUX_USER_PASSWORD" ]]; then
  echo "Please set 'LINUX_USER_PASSWORD' for user: $USER"
  exit 3
fi

# One mesh behind one interface. VPN_PROVIDER picks it; everything below only
# ever refers to $VPN_IP / $VPN_IFACE, so swapping providers is a variable.
source "$(dirname "$0")/scripts/vpn.sh"

# vpn_ip parses netbird's JSON status. Present on GitHub runners, absent on a
# fresh box — and without it vpn_ip returns empty and this looks like the mesh
# failed to come up.
command -v jq >/dev/null || { sudo apt-get update && sudo apt-get install -y jq; }

echo "### Install VPN ($VPN_PROVIDER) ###"

vpn_install

echo "### Update user: $USER password ###"
echo -e "$LINUX_USER_PASSWORD\n$LINUX_USER_PASSWORD" | sudo passwd "$USER"

echo "### Join the mesh as $LINUX_MACHINE_NAME ###"

vpn_up "$LINUX_MACHINE_NAME" || exit 4

# Retried inside vpn_ip: both daemons report the address a beat after `up`.
VPN_IP=$(vpn_ip)

if [[ -n "$VPN_IP" ]]; then
  echo ""
  echo "=========================================="
  echo "Mesh IP ($VPN_PROVIDER, $VPN_IFACE): $VPN_IP"
  echo "To connect: ssh $USER@$VPN_IP"
  echo "or connect with: ssh $USER@$LINUX_MACHINE_NAME"
  echo "=========================================="
else
  echo "Failed to get a mesh IP from $VPN_PROVIDER"
  exit 4
fi

# NFS client — required on every node so pods can mount NFS-backed PersistentVolumes.
# Without it kubelet's mount fails with "you might need a /sbin/mount.<type> helper program".
echo "### Install NFS client (nfs-common) ###"
sudo apt-get update && sudo apt-get install -y nfs-common

# Mode: if K3S_URL + K3S_TOKEN are set, join an existing cluster as a worker node.
#       Otherwise install as a standalone single-node server (control-plane + worker).
#   K3S_URL   : https://<server-mesh-ip>:6443
#   K3S_TOKEN : contents of /var/lib/rancher/k3s/server/node-token on the server
if [[ -n "$K3S_URL" && -n "$K3S_TOKEN" ]]; then
  echo "### Join k3s cluster as worker node -> $K3S_URL ###"

  # K3S_URL/K3S_TOKEN in the env make the installer run 'k3s agent' (no control-plane).
  # --with-node-id appends a unique suffix so two boxes sharing LINUX_MACHINE_NAME
  # don't collide ("Node password rejected, duplicate hostname").
  # NOTE: do NOT pass --kubelet-arg=shutdown-grace-period[-critical-pods]. Those
  # are not kubelet CLI flags (graceful shutdown is KubeletConfiguration-only),
  # so kubelet exits with "unknown flag" and the agent crashloops → never joins.
  # It also wouldn't help here: GitHub kills the 6h runner VM hard, not via a
  # clean systemd shutdown, so the inhibitor-based drain never fires anyway.
  curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -s - \
    --node-name "$LINUX_MACHINE_NAME" \
    --with-node-id \
    --node-ip "$VPN_IP" \
    --flannel-iface "$VPN_IFACE"

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
  # --tls-san $LINUX_MACHINE_NAME / $VPN_IP so kubectl works over the mesh from other machines.
  # --node-ip / --flannel-iface MUST match the agents (which join on the same mesh iface):
  # otherwise the server advertises its flannel VXLAN endpoint on the public NIC,
  # agents expect it on $VPN_IFACE, and cross-node pod traffic (incl. CoreDNS) breaks.
  curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644 \
    --node-name "$LINUX_MACHINE_NAME" \
    --node-ip "$VPN_IP" \
    --flannel-iface "$VPN_IFACE" \
    --tls-san "$LINUX_MACHINE_NAME" \
    --tls-san "$VPN_IP"

  echo "### Wait for k3s node to become Ready ###"
  until sudo k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; do
    echo "waiting for k3s..."
    sleep 3
  done

  # Make kubeconfig usable by the created login user (kubectl reads ~/.kube/config).
  sudo mkdir -p /home/$LINUX_USERNAME/.kube
  sudo cp /etc/rancher/k3s/k3s.yaml /home/$LINUX_USERNAME/.kube/config
  sudo sed -i "s/127.0.0.1/$VPN_IP/g" /home/$LINUX_USERNAME/.kube/config
  sudo chown -R $LINUX_USERNAME:$LINUX_USERNAME /home/$LINUX_USERNAME/.kube
  sudo ln -sf /usr/local/bin/kubectl /usr/local/bin/k 2>/dev/null || true

  echo ""
  echo "=========================================="
  echo "k3s ready. On this box:  sudo k3s kubectl get nodes"
  echo "As $LINUX_USERNAME:       kubectl get nodes"
  echo "Remote kubeconfig:       /home/$LINUX_USERNAME/.kube/config (API at https://$VPN_IP:6443)"
  echo "Join a worker: re-run this script on another box with K3S_URL=https://$VPN_IP:6443"
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