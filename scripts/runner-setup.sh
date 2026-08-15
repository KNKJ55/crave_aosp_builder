#!/usr/bin/env bash
# Copyright (C) 2024-2025 Souhrud Reddy
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

RUNNER_DIR="${RUNNER_DIR:-actions-runner}"
RUNNER_VERSION="${RUNNER_VERSION:-}"

case "$(uname -m)" in
  x86_64|amd64)
    RUNNER_ARCH="x64"
    ;;
  aarch64|arm64)
    RUNNER_ARCH="arm64"
    ;;
  armv7l|armv8l)
    RUNNER_ARCH="arm"
    ;;
  *)
    echo "Unsupported CPU architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$(uname -o 2>/dev/null || true)" == "Android" ]] || [[ -n "${TERMUX_VERSION:-}" ]]; then
  cat >&2 <<'EOF'
The official GitHub Actions runner cannot run in Android's native Bionic
environment. Run scripts/termux-runner.sh from Termux; it installs this runner
inside a proot Ubuntu environment.
EOF
  exit 1
fi

for command_name in curl tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

if [[ -z "$RUNNER_VERSION" ]]; then
  RUNNER_VERSION="$({
    curl --fail --silent --show-error --location \
      https://api.github.com/repos/actions/runner/releases/latest
  } | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n 1)"
fi

if [[ -z "$RUNNER_VERSION" ]]; then
  echo "Failed to retrieve the latest GitHub Actions runner version." >&2
  exit 1
fi

archive="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${archive}"
temporary_archive="$(mktemp "${TMPDIR:-/tmp}/actions-runner.XXXXXX.tar.gz")"
trap 'rm -f "$temporary_archive"' EXIT

echo "Downloading GitHub Actions runner ${RUNNER_VERSION} for linux-${RUNNER_ARCH}..."
curl --fail --location --retry 3 --output "$temporary_archive" "$url"

if [[ -e "$RUNNER_DIR" ]]; then
  if [[ "${RUNNER_REPLACE:-0}" != "1" ]]; then
    echo "$RUNNER_DIR already exists. Set RUNNER_REPLACE=1 to replace it." >&2
    exit 1
  fi
  rm -rf -- "$RUNNER_DIR"
fi

mkdir -p "$RUNNER_DIR"
tar -xzf "$temporary_archive" -C "$RUNNER_DIR"
echo "Runner extracted to $RUNNER_DIR"
