#linux-ser.sh  LINUX_MACHINE_NAME K3S_URL K3S_TOKEN [VPN_PROVIDER]
#!/bin/bash
#
# Joins this box to an existing k3s cluster as a worker node, over the VPN mesh.
# That is all it does: no login user, no GitHub runner, no config sync. The box
# is ephemeral (a GitHub runner, killed at 6h) and owns no state — everything it
# would need is either on the control plane or in the cluster.
#
# The mesh is whichever scripts/vpn.sh selects (VPN_PROVIDER=netbird|tailscale,
# default netbird). Its keys are that provider's:
#   netbird   : NETBIRD_MANAGEMENT_URL, NETBIRD_SETUP_KEY
#   tailscale : TAILSCALE_AUTH_KEY

# One mesh behind one interface. VPN_PROVIDER picks it; everything below only
# ever refers to $VPN_IP / $VPN_IFACE, so swapping providers is a variable.
source "$(dirname "$0")/scripts/vpn.sh"

# vpn_ip parses netbird's JSON status. Present on GitHub runners, absent on a
# fresh box — and without it vpn_ip returns empty and this looks like the mesh
# failed to come up.
command -v jq >/dev/null || { sudo apt-get update && sudo apt-get install -y jq; }

echo "### Install VPN ($VPN_PROVIDER) ###"

vpn_install

echo "### Join the mesh as $LINUX_MACHINE_NAME ###"

vpn_up "$LINUX_MACHINE_NAME" || exit 4

# Retried inside vpn_ip: both daemons report the address a beat after `up`.
VPN_IP=$(vpn_ip)

if [[ -n "$VPN_IP" ]]; then
  echo ""
  echo "=========================================="
  echo "Mesh IP ($VPN_PROVIDER, $VPN_IFACE): $VPN_IP"
  echo "To connect: netbird ssh root@$VPN_IP"
  echo "=========================================="
else
  echo "Failed to get a mesh IP from $VPN_PROVIDER"
  exit 4
fi

# NFS client — required on every node so pods can mount NFS-backed PersistentVolumes.
# Without it kubelet's mount fails with "you might need a /sbin/mount.<type> helper program".
echo "### Install NFS client (nfs-common) ###"
sudo apt-get update && sudo apt-get install -y nfs-common

#   K3S_URL   : https://<server-mesh-ip>:6443
#   K3S_TOKEN : contents of /var/lib/rancher/k3s/server/node-token on the server
#
# Both are mandatory. get.k3s.io reads them straight from the environment and
# only runs `k3s agent` when they are present — unset, it silently installs a
# whole standalone server instead, so a typo would grow a second cluster rather
# than fail.
if [[ -z "$K3S_URL" || -z "$K3S_TOKEN" ]]; then
  echo "K3S_URL and K3S_TOKEN are required — this script only joins an existing cluster."
  exit 5
fi

# get.k3s.io rejects anything without a scheme, but its message quotes the URL
# back — which Actions masks to *** because it is a secret. Check it here so
# the failure names the problem instead of showing "have ***".
if [[ "$K3S_URL" != https://* ]]; then
  echo "K3S_URL must start with https:// and include the port, e.g. https://<mesh-ip>:6443"
  exit 5
fi

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
  --flannel-iface "$VPN_IFACE" || { echo "k3s agent install failed"; exit 5; }

# The installer ends in `systemctl restart k3s-agent`, which blocks until the
# unit is ready — so reaching here usually means it joined. Usually: a server
# that answers but rejects the node leaves the unit "activating" forever and
# the restart never returns, so this check is what turns a silent hang into a
# named failure once systemd gives up.
if ! systemctl is-active --quiet k3s-agent; then
  echo "k3s-agent is not active — the node did not join. Last errors:"
  sudo journalctl -u k3s-agent --no-pager -n 20
  exit 5
fi

echo ""
echo "=========================================="
echo "Joined as worker node: $LINUX_MACHINE_NAME"
echo "Verify from the SERVER: kubectl get nodes"
echo "Agent status here:      sudo systemctl status k3s-agent"
echo "=========================================="
