#linux-ser.sh LINUX_USER_PASSWORD TAILSCALE_AUTH_KEY LINUX_USERNAME LINUX_MACHINE_NAME
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
echo "Join more nodes: run 'k3s agent' with token from /var/lib/rancher/k3s/server/node-token"
echo "=========================================="
