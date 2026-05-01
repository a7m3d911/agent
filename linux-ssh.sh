#linux-run.sh LINUX_USER_PASSWORD TAILSCALE_AUTH_KEY LINUX_USERNAME LINUX_MACHINE_NAME GH_TOKEN WS_SECRET WORKFLOW_SERVER RUNNER_URL RUNNER_TOKEN [RUNNER_LABELS]
#!/bin/bash

sudo useradd -m $LINUX_USERNAME
sudo adduser $LINUX_USERNAME sudo
echo "$LINUX_USERNAME:$LINUX_USER_PASSWORD" | sudo chpasswd
sed -i 's/\/bin\/sh/\/bin\/bash/g' /etc/passwd
sudo hostname $LINUX_MACHINE_NAME

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

echo "### Install GitHub CLI ###"

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli-stable.list > /dev/null
sudo apt update
sudo apt install gh -y

echo "### Authenticate GitHub CLI ###"

echo "$GH_TOKEN" | gh auth login --with-token

echo "### Download workflow agent from release ###"

ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
  AGENT_BINARY="workflow-agent-linux-arm64"
else
  AGENT_BINARY="workflow-agent-linux-amd64"
fi

gh release download v1.0.3 --pattern "$AGENT_BINARY" --repo marbit-io/workflow --dir /usr/local/bin
chmod +x /usr/local/bin/$AGENT_BINARY
ln -sf /usr/local/bin/$AGENT_BINARY /usr/local/bin/workflow-agent

echo "### Start workflow agent ###"

workflow-agent --protocol websocket --ws-secret "$WS_SECRET" --server "$WORKFLOW_SERVER" &

echo "### Install GitHub Actions self-hosted runner ###"

if [[ -z "$RUNNER_URL" ]]; then
  echo "Please set 'RUNNER_URL' (e.g. https://github.com/marbit-io)"
  exit 5
fi

if [[ -z "$RUNNER_TOKEN" ]]; then
  echo "Please set 'RUNNER_TOKEN' (registration token)"
  exit 6
fi

RUNNER_VERSION="2.334.0"
RUNNER_ARCH=$(dpkg --print-architecture)
if [[ "$RUNNER_ARCH" == "arm64" || "$RUNNER_ARCH" == "aarch64" ]]; then
  RUNNER_PACKAGE="actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"
else
  RUNNER_PACKAGE="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
fi

RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,$(dpkg --print-architecture)}"

sudo -u "$LINUX_USERNAME" -H bash <<EOF
set -e
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o "$RUNNER_PACKAGE" -L "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_PACKAGE}"
tar xzf "./$RUNNER_PACKAGE"
./config.sh \
  --url "$RUNNER_URL" \
  --token "$RUNNER_TOKEN" \
  --name "$LINUX_MACHINE_NAME" \
  --labels "$RUNNER_LABELS" \
  --unattended --replace
nohup ./run.sh > runner.log 2>&1 &
EOF
