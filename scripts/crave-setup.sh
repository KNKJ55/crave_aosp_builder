#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

CRAVE_BIN_DIR="${CRAVE_BIN_DIR:-$HOME/bin}"
CRAVE_CONFIG="${CRAVE_CONFIG:-$HOME/crave.conf}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to install the Crave CLI." >&2
  exit 1
fi

mkdir -p "$CRAVE_BIN_DIR"
export PATH="$CRAVE_BIN_DIR:$PATH"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$CRAVE_BIN_DIR" >> "$GITHUB_PATH"
fi

if ! command -v crave >/dev/null 2>&1; then
  temporary_dir="$(mktemp -d)"
  trap 'rm -rf "$temporary_dir"' EXIT

  echo "Installing the Crave CLI for $(uname -m) into $CRAVE_BIN_DIR..."
  (
    cd "$temporary_dir"
    curl --fail --silent --show-error --location \
      https://raw.githubusercontent.com/accupara/crave/master/get_crave.sh \
      | bash -s --
    install -m 0755 crave "$CRAVE_BIN_DIR/crave"
  )
fi

if [[ -f "${CRAVE_CONFIG_TEMPLATE:-crave.conf.sample}" ]]; then
  : "${CRAVE_USERNAME:?CRAVE_USERNAME is required to create crave.conf}"
  : "${CRAVE_TOKEN:?CRAVE_TOKEN is required to create crave.conf}"

  if ! command -v envsubst >/dev/null 2>&1; then
    echo "envsubst is required to create crave.conf (install gettext-base)." >&2
    exit 1
  fi

  umask 077
  envsubst < "${CRAVE_CONFIG_TEMPLATE:-crave.conf.sample}" > "$CRAVE_CONFIG"
  echo "Crave configuration written to $CRAVE_CONFIG"

  # Older Crave CLI builds look in the current directory while newer workflow
  # steps use ~/crave.conf explicitly. Keep both lookup locations consistent.
  if [[ "$(pwd)/crave.conf" != "$CRAVE_CONFIG" ]]; then
    ln -sfn "$CRAVE_CONFIG" "$(pwd)/crave.conf"
  fi
fi

crave version 2>/dev/null || crave --version 2>/dev/null || true
