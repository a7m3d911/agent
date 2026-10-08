#!/usr/bin/env bash
# Tailscale + Brain: a cloud worker when BRAIN_WORKER_POOL_TOKEN is set,
# otherwise a remote-shared device. Nothing else.
set -euo pipefail

[[ -n "${BRAIN_WORKER_POOL_TOKEN:-}" || -n "${BRAIN_CLOUD_TOKEN:-}" ]] || { echo "BRAIN_WORKER_POOL_TOKEN or BRAIN_CLOUD_TOKEN must be set" >&2; exit 1; }
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

if [[ -n "${GH_TOKEN:-}" ]]; then
  echo "### Install + auth gh ###"
  command -v gh >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq gh; }
  # env -u: gh refuses to store a login while GH_TOKEN is set; XDG_CONFIG_HOME points at the runner's dir.
  echo "$GH_TOKEN" | env -u GH_TOKEN -u XDG_CONFIG_HOME gh auth login --with-token
  env -u GH_TOKEN -u XDG_CONFIG_HOME gh auth status
else
  echo "GH_TOKEN unset — skipping gh auth"
fi

echo "### Install Brain ###"
curl -fsSL https://raw.githubusercontent.com/ahmed3mar/brain/main/install.sh | sh
# ponytail: the installer may drop the binary in a user bin dir not on PATH yet.
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"
[[ -n "${GITHUB_PATH:-}" ]] && echo "$HOME/.local/bin" >> "$GITHUB_PATH"

if [[ -n "${BRAIN_WORKER_POOL_TOKEN:-}" ]]; then
  # Registers its own worker in the pool; later steps drain and hand off its tasks.
  nohup brain worker --cloud "${BRAIN_CLOUD_URL:-https://brain.ahmed3mar.com}" \
    --pool-token "$BRAIN_WORKER_POOL_TOKEN" --name "$LINUX_MACHINE_NAME" \
    --max-tasks "${BRAIN_WORKER_MAX_TASKS:-3}" --root "${RUNNER_TEMP:-$HOME}/brain" \
    > "$HOME/brain-worker.log" 2>&1 &
  sleep 10
  cat "$HOME/brain-worker.log" || true
  kill -0 $! # fail the step if the worker already exited
  exit 0
fi

brain daemon start
echo "$BRAIN_CLOUD_TOKEN" | brain user login --with-token

# Backgrounded so the step returns whether `share on` daemonizes or blocks;
# the job's sleeps keep the box (and this process) alive.
nohup brain remote share on > "$HOME/brain-share.log" 2>&1 &
sleep 5
cat "$HOME/brain-share.log" || true
