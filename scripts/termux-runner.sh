#!/data/data/com.termux/files/usr/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

DISTRO_ALIAS="${TERMUX_RUNNER_DISTRO:-ubuntu}"
RUNNER_ROOT="${TERMUX_RUNNER_ROOT:-/opt/actions-runner}"
TMUX_SESSION="${TERMUX_RUNNER_SESSION:-github-actions-runner}"
RUNNER_LABELS="${TERMUX_RUNNER_LABELS:-termux,android}"
SCRIPT_PATH="$(realpath "$0")"

usage() {
  cat <<'EOF'
Usage:
  termux-runner.sh setup --url URL --token TOKEN [--name NAME]
  termux-runner.sh start
  termux-runner.sh stop
  termux-runner.sh restart
  termux-runner.sh status
  termux-runner.sh logs
  termux-runner.sh enable-boot

The setup command installs Ubuntu through proot-distro, downloads the runner
matching the phone CPU, registers it with the labels "termux" and "android",
and starts it in tmux. RUNNER_URL and RUNNER_TOKEN may be used instead of flags.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

is_termux() {
  [[ -n "${TERMUX_VERSION:-}" ]] || [[ "${PREFIX:-}" == *com.termux* ]]
}

require_termux() {
  is_termux || die "Run this script in the Termux host shell, not inside Ubuntu."
}

distro_exec() {
  proot-distro login "$DISTRO_ALIAS" -- "$@"
}

distro_is_installed() {
  proot-distro login "$DISTRO_ALIAS" -- true >/dev/null 2>&1
}

runner_is_configured() {
  distro_is_installed && distro_exec test -f "$RUNNER_ROOT/.runner" >/dev/null 2>&1
}

install_host_dependencies() {
  echo "Installing Termux host dependencies..."
  pkg install -y proot-distro tmux curl coreutils

  if ! distro_is_installed; then
    echo "Installing the $DISTRO_ALIAS proot distribution..."
    proot-distro install "$DISTRO_ALIAS"
  fi
}

runner_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv8l) echo arm ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

install_distro_dependencies() {
  echo "Installing runner dependencies in Ubuntu..."
  distro_exec env DEBIAN_FRONTEND=noninteractive apt-get update
  distro_exec env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    bash ca-certificates curl gettext-base git gnupg gzip jq python3 tar
}

install_runner() {
  local arch version archive url
  arch="$(runner_arch)"

  version="$(curl --fail --silent --show-error --location \
    https://api.github.com/repos/actions/runner/releases/latest \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' \
    | head -n 1)"
  [[ -n "$version" ]] || die "Unable to determine the latest runner version."

  archive="actions-runner-linux-${arch}-${version}.tar.gz"
  url="https://github.com/actions/runner/releases/download/v${version}/${archive}"

  echo "Downloading runner $version for linux-$arch inside Ubuntu..."
  distro_exec mkdir -p "$RUNNER_ROOT"
  distro_exec curl --fail --location --retry 3 --output "/tmp/$archive" "$url"
  distro_exec tar -xzf "/tmp/$archive" -C "$RUNNER_ROOT"
  distro_exec rm -f "/tmp/$archive"

  # GitHub maintains this script alongside the runner and updates the distro
  # dependency list as the embedded .NET runtime changes.
  distro_exec env RUNNER_ALLOW_RUNASROOT=1 \
    bash -c 'cd "$1" && ./bin/installdependencies.sh' _ "$RUNNER_ROOT"
}

setup_runner() {
  local runner_url="${RUNNER_URL:-}"
  local runner_token="${RUNNER_TOKEN:-}"
  local runner_name="${TERMUX_RUNNER_NAME:-termux-$(uname -m)}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)
        [[ $# -ge 2 ]] || die "--url requires a value."
        runner_url="$2"
        shift 2
        ;;
      --token)
        [[ $# -ge 2 ]] || die "--token requires a value."
        runner_token="$2"
        shift 2
        ;;
      --name)
        [[ $# -ge 2 ]] || die "--name requires a value."
        runner_name="$2"
        shift 2
        ;;
      *)
        die "Unknown setup option: $1"
        ;;
    esac
  done

  [[ -n "$runner_url" ]] || die "Provide --url (for example, https://github.com/owner/repo)."
  [[ -n "$runner_token" ]] || die "Provide the short-lived token shown on GitHub's New runner page."

  install_host_dependencies
  install_distro_dependencies
  if ! runner_is_configured; then
    install_runner
    echo "Registering runner $runner_name..."
    distro_exec env RUNNER_ALLOW_RUNASROOT=1 \
      bash -c 'cd "$1"; shift; exec ./config.sh "$@"' _ "$RUNNER_ROOT" \
      --unattended \
      --url "$runner_url" \
      --token "$runner_token" \
      --name "$runner_name" \
      --labels "$RUNNER_LABELS" \
      --work _work \
      --replace
  else
    echo "Runner is already configured in $DISTRO_ALIAS:$RUNNER_ROOT; keeping its registration."
  fi

  start_runner
}

start_runner() {
  local tmux_command
  runner_is_configured || die "Runner is not configured. Run '$SCRIPT_PATH setup ...' first."

  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "Runner is already active in tmux session $TMUX_SESSION."
    return
  fi

  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock || true
  fi

  printf -v tmux_command '%q %q' "$SCRIPT_PATH" _run
  tmux new-session -d -s "$TMUX_SESSION" "$tmux_command"
  sleep 2

  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "Runner started in tmux session $TMUX_SESSION."
    echo "Use '$SCRIPT_PATH logs' to inspect its latest output."
  else
    die "Runner exited during startup. Run '$SCRIPT_PATH logs' and inspect $RUNNER_ROOT/_diag in Ubuntu."
  fi
}

run_foreground() {
  exec proot-distro login "$DISTRO_ALIAS" -- \
    env RUNNER_ALLOW_RUNASROOT=1 \
    bash -c 'cd "$1" && exec ./run.sh' _ "$RUNNER_ROOT"
}

stop_runner() {
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "Runner is not active."
    return
  fi

  tmux send-keys -t "$TMUX_SESSION" C-c
  for _ in 1 2 3 4 5; do
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null || break
    sleep 1
  done
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  echo "Runner stopped."
}

status_runner() {
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "Runner process: active (tmux session $TMUX_SESSION)"
  else
    echo "Runner process: stopped"
  fi

  if runner_is_configured; then
    echo "Runner configuration: present in $DISTRO_ALIAS:$RUNNER_ROOT"
  else
    echo "Runner configuration: missing"
    return 1
  fi
}

show_logs() {
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux capture-pane -p -t "$TMUX_SESSION" -S -200
  elif distro_is_installed; then
    distro_exec bash -c \
      'latest=$(find "$1/_diag" -maxdepth 1 -type f -name "Runner_*.log" 2>/dev/null | sort | tail -n 1); [[ -n "$latest" ]] && tail -n 200 "$latest"' \
      _ "$RUNNER_ROOT"
  else
    die "$DISTRO_ALIAS is not installed."
  fi
}

enable_boot() {
  local boot_dir="$HOME/.termux/boot"
  local boot_script="$boot_dir/github-actions-runner"

  mkdir -p "$boot_dir"
  {
    echo '#!/data/data/com.termux/files/usr/bin/bash'
    printf 'exec %q start\n' "$SCRIPT_PATH"
  } > "$boot_script"
  chmod 0700 "$boot_script"

  echo "Boot launcher installed at $boot_script"
  echo "Install and open the Termux:Boot app once to activate boot scripts."
}

require_termux

command_name="${1:-}"
[[ $# -eq 0 ]] || shift
case "$command_name" in
  setup) setup_runner "$@" ;;
  start) start_runner ;;
  stop) stop_runner ;;
  restart) stop_runner; start_runner ;;
  status) status_runner ;;
  logs) show_logs ;;
  enable-boot) enable_boot ;;
  _run) run_foreground ;;
  help|-h|--help|'') usage ;;
  *) usage >&2; exit 1 ;;
esac
