#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

REPO_BIN_DIR="${REPO_BIN_DIR:-$HOME/bin}"
mkdir -p "$REPO_BIN_DIR"
export PATH="$REPO_BIN_DIR:$PATH"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$REPO_BIN_DIR" >> "$GITHUB_PATH"
fi

if command -v repo >/dev/null 2>&1; then
  echo "repo is already installed at $(command -v repo)"
  exit 0
fi

for command_name in curl git python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command for repo: $command_name" >&2
    exit 1
  fi
done

echo "Installing repo into $REPO_BIN_DIR..."
curl --fail --silent --show-error --location \
  https://storage.googleapis.com/git-repo-downloads/repo \
  --output "$REPO_BIN_DIR/repo"
chmod 0755 "$REPO_BIN_DIR/repo"
repo version
