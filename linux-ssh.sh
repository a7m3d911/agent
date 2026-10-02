#linux-run.sh LINUX_USER_PASSWORD NETBIRD_MANAGEMENT_URL NETBIRD_SETUP_KEY LINUX_USERNAME LINUX_MACHINE_NAME GH_TOKEN WS_SECRET WORKFLOW_SERVER [RUNNER_ORG] [RUNNER_LABELS]
#!/bin/bash

# Unique per run: overlapping boxes in the chain must not share a NetBird name.
LINUX_MACHINE_NAME="${LINUX_MACHINE_NAME}-${GITHUB_RUN_ID}"

sudo useradd -m $LINUX_USERNAME
sudo adduser $LINUX_USERNAME sudo
echo "$LINUX_USERNAME:$LINUX_USER_PASSWORD" | sudo chpasswd
sudo sed -i 's/\/bin\/sh/\/bin\/bash/g' /etc/passwd
sudo hostname $LINUX_MACHINE_NAME

if [[ -z "$LINUX_USER_PASSWORD" ]]; then
  echo "Please set 'LINUX_USER_PASSWORD' for user: $USER"
  exit 3
fi

# if [[ -z "$NETBIRD_MANAGEMENT_URL" || -z "$NETBIRD_SETUP_KEY" ]]; then
#   echo "Please set 'NETBIRD_MANAGEMENT_URL' and 'NETBIRD_SETUP_KEY'"
#   exit 2
# fi

# Second way in, independent of NetBird. Optional: skipped when the key is unset.
if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
  echo "### Install Tailscale ###"
  curl -fsSL https://tailscale.com/install.sh | sh
  # --accept-dns=false: don't fight NetBird over resolv.conf.
  sudo timeout 60 tailscale up --authkey="$TAILSCALE_AUTH_KEY" --ssh --hostname="$LINUX_MACHINE_NAME" --accept-dns=false \
    && echo "Tailscale: ssh $USER@$LINUX_MACHINE_NAME ($(tailscale ip -4))" \
    || echo "Failed to start Tailscale"
else
  echo "TAILSCALE_AUTH_KEY unset — skipping Tailscale"
fi

# echo "### Install netbird ###"
# curl -fsSL https://pkgs.netbird.io/install.sh | sh

echo "### Update user: $USER password ###"
echo -e "$LINUX_USER_PASSWORD\n$LINUX_USER_PASSWORD" | sudo passwd "$USER"

# ponytail: gh is preinstalled on ubuntu-latest; the apt update here hung the step.

echo "### Download workflow agent from release ###"

ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
  AGENT_BINARY="workflow-agent-linux-arm64"
else
  AGENT_BINARY="workflow-agent-linux-amd64"
fi

timeout 120 gh release download v1.0.3 --pattern "$AGENT_BINARY" --repo marbit-io/workflow --dir /usr/local/bin
chmod +x /usr/local/bin/$AGENT_BINARY
ln -sf /usr/local/bin/$AGENT_BINARY /usr/local/bin/workflow-agent

echo "### Persist gh auth for SSH users ###"
# env -u: gh refuses to store a login while GH_TOKEN is set (SSH sessions don't get it), and the runner's XDG_CONFIG_HOME would point every user at /home/runner/.config.
for u in "$USER" "$LINUX_USERNAME" root; do
  echo "$GH_TOKEN" | sudo -u "$u" -H env -u GH_TOKEN -u XDG_CONFIG_HOME timeout 60 gh auth login --with-token
done

# # Network calls go BEFORE netbird up: every run hung on the first one made after it.
# sudo netbird up --management-url "$NETBIRD_MANAGEMENT_URL" --setup-key "$NETBIRD_SETUP_KEY" --hostname "$LINUX_MACHINE_NAME" --allow-server-ssh --enable-ssh-root



echo "### Start workflow agent ###"

# Detach stdio: a background child holding the step's stdout pipe keeps the step "running" forever.
nohup workflow-agent --protocol websocket --ws-secret "$WS_SECRET" --server "$WORKFLOW_SERVER" > /tmp/workflow-agent.log 2>&1 < /dev/null &

echo "### Install GitHub Actions self-hosted runner ###"

# RUNNER_ORG="${RUNNER_ORG:-marbit-io}"

# echo "### Mint org runner registration token for '$RUNNER_ORG' ###"
# if ! RUNNER_TOKEN=$(gh api -X POST "orgs/$RUNNER_ORG/actions/runners/registration-token" --jq .token); then
#   echo "Failed to mint registration token for org '$RUNNER_ORG'"
#   echo "Hint: GH_TOKEN must have 'admin:org' scope on $RUNNER_ORG"
#   exit 6
# fi
# if [[ -z "$RUNNER_TOKEN" ]]; then
#   echo "Empty registration token returned for org '$RUNNER_ORG'"
#   exit 6
# fi

# RUNNER_VERSION="2.334.0"
# RUNNER_ARCH=$(dpkg --print-architecture)
# if [[ "$RUNNER_ARCH" == "arm64" || "$RUNNER_ARCH" == "aarch64" ]]; then
#   RUNNER_PACKAGE="actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"
# else
#   RUNNER_PACKAGE="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
# fi

# RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,$(dpkg --print-architecture)}"

# sudo -u "$LINUX_USERNAME" -H bash <<EOF
# set -e
# mkdir -p ~/actions-runner && cd ~/actions-runner
# curl -o "$RUNNER_PACKAGE" -L "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_PACKAGE}"
# tar xzf "./$RUNNER_PACKAGE"
# ./config.sh \
#   --url "https://github.com/$RUNNER_ORG" \
#   --token "$RUNNER_TOKEN" \
#   --name "$LINUX_MACHINE_NAME" \
#   --labels "$RUNNER_LABELS" \
#   --unattended --replace
# nohup ./run.sh > runner.log 2>&1 &
# EOF
