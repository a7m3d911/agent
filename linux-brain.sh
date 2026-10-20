#!/usr/bin/env bash
# Tailscale + Brain: a cloud worker when BRAIN_WORKER_POOL_TOKEN is set,
# otherwise a remote-shared device. Nothing else.
set -euo pipefail

[[ -n "${BRAIN_WORKER_POOL_TOKEN:-}" || -n "${BRAIN_CLOUD_TOKEN:-}" ]] || { echo "BRAIN_WORKER_POOL_TOKEN or BRAIN_CLOUD_TOKEN must be set" >&2; exit 1; }
LINUX_MACHINE_NAME="${LINUX_MACHINE_NAME:-brain}"

if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
  echo "### Install Tailscale ###"
  if [[ "$(uname)" == Darwin ]]; then
    # Same as macos-run.sh: brew's tailscale has no service, so run the daemon ourselves.
    brew install tailscale coreutils  # coreutils: macOS has no `timeout` (brew names it gtimeout)
    sudo tailscaled --state=/var/lib/tailscale/tailscaled.state > /tmp/tailscaled.log 2>&1 &
    sleep 3
  else
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  sudo "$(command -v timeout || command -v gtimeout)" 60 tailscale up --authkey="$TAILSCALE_AUTH_KEY" --ssh --hostname="$LINUX_MACHINE_NAME" --accept-dns=false \
    && echo "Tailscale: $LINUX_MACHINE_NAME ($(tailscale ip -4))" \
    || echo "Failed to start Tailscale"
else
  echo "TAILSCALE_AUTH_KEY unset — skipping Tailscale"
fi

if [[ -n "${GH_TOKEN:-}" ]]; then
  echo "### Install + auth gh ###"
  command -v gh >/dev/null || { [[ "$(uname)" == Darwin ]] && brew install gh || { sudo apt-get update -qq && sudo apt-get install -y -qq gh; }; }
  # env -u: gh refuses to store a login while GH_TOKEN is set; XDG_CONFIG_HOME points at the runner's dir.
  echo "$GH_TOKEN" | env -u GH_TOKEN -u XDG_CONFIG_HOME gh auth login --with-token
  env -u GH_TOKEN -u XDG_CONFIG_HOME gh auth status
else
  echo "GH_TOKEN unset — skipping gh auth"
fi

echo "### Install Brain ###"
# The installer asks api.github.com anonymously, and shared runner IPs hit the 60/h limit (403).
# Resolve the version with the authed gh instead; empty → installer falls back to its own lookup.
if [[ -z "${BRAIN_VERSION:-}" ]] && command -v gh >/dev/null; then
  BRAIN_VERSION="$(gh release view --repo ahmed3mar/brain --json tagName -q .tagName 2>/dev/null || true)"
  [[ -n "$BRAIN_VERSION" ]] && export BRAIN_VERSION="${BRAIN_VERSION#v}"
fi
curl -fsSL https://raw.githubusercontent.com/ahmed3mar/brain/main/install.sh | sh
# ponytail: the installer may drop the binary in a user bin dir not on PATH yet.
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"
[[ -n "${GITHUB_PATH:-}" ]] && echo "$HOME/.local/bin" >> "$GITHUB_PATH"

if [[ -n "${E2E_POOL_TOKEN:-}" ]]; then
  echo "### Start e2e worker ###"
  # @marbit/* lives on the private registry. The literal ${NPM_TOKEN} is expanded
  # by npm at read time, so the token never lands on disk.
  if [[ -n "${NPM_TOKEN:-}" ]]; then
    printf '%s\n' '@marbit:registry=https://registry.marbit.dev/' \
      '//registry.marbit.dev/:_authToken=${NPM_TOKEN}' >> "$HOME/.npmrc"
  fi
  # Its own process next to Brain, in both worker and device mode.
  # ponytail: no drain/handoff; it dies with the VM. Add one if e2e runs get cut mid-test.
  nohup env E2E_API_URL="${E2E_API_URL:?E2E_API_URL unset}" E2E_POOL_TOKEN="$E2E_POOL_TOKEN" \
    npx -y @marbit/e2e-worker@latest > "$HOME/e2e-worker.log" 2>&1 < /dev/null &
  E2E_PID=$!
  sleep 15
  cat "$HOME/e2e-worker.log" || true
  kill -0 "$E2E_PID" # fail the step if the e2e worker already exited
fi

if [[ -n "${BRAIN_WORKER_POOL_TOKEN:-}" ]]; then
  # Registers its own worker in the pool; later steps drain and hand off its tasks.
  export BRAIN_WORKER_ROOT="${RUNNER_TEMP:-$HOME}/brain"
  # `brain worker drain` in later steps finds the worker through this.
  [[ -n "${GITHUB_ENV:-}" ]] && echo "BRAIN_WORKER_ROOT=$BRAIN_WORKER_ROOT" >> "$GITHUB_ENV"
  nohup brain worker --cloud "${BRAIN_CLOUD_URL:-https://brain.ahmed3mar.com}" \
    --pool-token "$BRAIN_WORKER_POOL_TOKEN" --name "$LINUX_MACHINE_NAME" \
    --max-tasks "${BRAIN_WORKER_MAX_TASKS:-3}" --root "$BRAIN_WORKER_ROOT" \
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
