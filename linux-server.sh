#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-a7m3d911/agent}"
DIR="${DIR:-/opt/agent}"

if ! command -v gh >/dev/null; then
  # ponytail: official apt install; swap for the dnf/apk block if this ever runs on non-Debian
  apt-get update
  apt-get install -y curl git
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update
  apt-get install -y gh
fi

if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only
else
  gh repo clone "$REPO" "$DIR"
fi

cd "$DIR"
exec ./dev-server/init.sh
