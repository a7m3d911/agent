#!/usr/bin/env bash
# Tailscale + Brain remote share. Nothing else.
set -euo pipefail

: "${BRAIN_CLOUD_TOKEN:?BRAIN_CLOUD_TOKEN unset}"
LINUX_MACHINE_NAME="${LINUX_MACHINE_NAME:-brain}"

if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
  echo "### Install Tailscale ###"
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo timeout 60 tailscale up --authkey="$TAILSCALE_AUTH_KEY" --ssh --hostname="$LINUX_MACHINE_NAME" --accept-dns=false \
    && echo "Tailscale: $LINUX_MACHINE_NAME ($(tailscale ip -4))" \
    || echo "Failed to start Tailscale"
else
  echo "TAILSCALE_AUTH_KEY unset — skipping Tailscale"
fi

echo "### Install Brain ###"
curl -fsSL https://raw.githubusercontent.com/ahmed3mar/brain/main/install.sh | sh
# ponytail: the installer may drop the binary in a user bin dir not on PATH yet.
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"
[[ -n "${GITHUB_PATH:-}" ]] && echo "$HOME/.local/bin" >> "$GITHUB_PATH"

echo "$BRAIN_CLOUD_TOKEN" | brain user login --with-token

# Backgrounded so the step returns whether `share on` daemonizes or blocks;
# the job's sleeps keep the box (and this process) alive.
nohup brain remote share on > "$HOME/brain-share.log" 2>&1 &
sleep 5
cat "$HOME/brain-share.log" || true
