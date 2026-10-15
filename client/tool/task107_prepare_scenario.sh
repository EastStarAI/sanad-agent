#!/usr/bin/env bash
# Scenario preparation for client/tool/task107_real_linux_verification.dart
#
# Prepares one REAL Linux host state for a Task 107 G5-R scenario using the
# published Agent releases, so the real controller can be driven against real
# binaries, a real Sanad Home, and a real systemd user unit.
#
# Usage:
#   task107_prepare_scenario.sh <A|B|C> <root> <port> [target-version]
#   task107_prepare_scenario.sh cleanup <root> <port>
#
# Scenarios:
#   A  stopped older Agent + unregistered service  -> expect auto-update, register, start
#   B  running older Agent under systemd + registered service -> expect real update execution
#   C  running target-version Agent started manually + unregistered service -> expect registration
#
# Then run, from the client/ directory:
#   TASK107_ROOT=<root> TASK107_SCENARIO=<A|B|C> SANAD_HOME=<root>/.sanad \
#     SANAD_SERVICE_INSTANCE=<instance> TASK107_KEEP=1 \
#     fvm flutter test tool/task107_real_linux_verification.dart \
#     --dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:<port>
#
# Scenario C starts an unmanaged daemon, so its prep must run in the SAME shell
# that runs the test (a supervisor launched in a background shell can be reaped
# when that shell exits).
#
# Environment:
#   SANAD_SERVICE_INSTANCE  systemd user unit instance suffix (default: task107)
#   TASK107_OLD_VERSION     older Agent version to install (default: 1.0.15)
#   TASK107_TARGET_VERSION  target Agent version (default: 1.0.17)
#
# This script never uses sudo, never changes linger, and never installs a
# system-scope service.

set -euo pipefail

RELEASE_BASE="https://github.com/EastStarAI/sanad-agent/releases/download"
INSTANCE="${SANAD_SERVICE_INSTANCE:-task107}"
OLD_VERSION="${TASK107_OLD_VERSION:-1.0.15}"
TARGET_VERSION="${TASK107_TARGET_VERSION:-1.0.17}"
UNIT_NAME="sanad-agent-${INSTANCE}.service"
UNIT_PATH="$HOME/.config/systemd/user/${UNIT_NAME}"

die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "this scenario harness is Linux-only"

require_systemd_user() {
  [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ] ||
    die "no systemd user bus; log in to a real user session first"
}

download_agent() {
  local version="$1" dest="$2"
  local url="${RELEASE_BASE}/v${version}/sanad-agent-${version}-linux-x64"
  echo "downloading $url" >&2
  curl -fsSL -o "$dest" "$url" || die "download failed for v$version"
  chmod 700 "$dest"
  # The Agent binary resolves the version it reports from the current working
  # directory, so running it from a source checkout reports THAT checkout's
  # version instead of the artifact's own. Pin both the cwd and the Sanad Home
  # to the scenario root, and capture output instead of piping into `grep -q`
  # (early reader exit closes the pipe, which `pipefail` reports as a SIGPIPE
  # failure of the binary).
  local home reported
  home="$(dirname "$(dirname "$dest")")"
  reported="$(cd "$home" && SANAD_HOME="$home" "$dest" --version 2>&1 || true)"
  case "$reported" in
    *"$version"*) ;;
    *) die "downloaded binary does not report version $version (got: ${reported//$'\n'/ })" ;;
  esac
}

remove_unit() {
  systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
  systemctl --user disable "$UNIT_NAME" 2>/dev/null || true
  rm -f "$UNIT_PATH"
  systemctl --user daemon-reload 2>/dev/null || true
}

write_unit() {
  local home="$1"
  mkdir -p "$(dirname "$UNIT_PATH")"
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Sanad Local Agent Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart="$home/bin/sanad" "daemon"
WorkingDirectory=$home
Environment="HOME=$HOME"
Environment="SANAD_HOME=$home"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
}

wait_for_health() {
  local home="$1" port="$2" expected="$3"
  local token="" version=""
  # Cold starts in a fresh Sanad Home (database init plus bundled skill sync)
  # can take well over a minute, so allow a generous budget.
  for _ in $(seq 1 150); do
    token="$(cat "$home/.local_token" 2>/dev/null || true)"
    version="$(curl -s -m 2 -H "x-sanad-local-token: $token" \
      "http://127.0.0.1:${port}/health" 2>/dev/null |
      grep -o '"version":"[^"]*"' || true)"
    [ -n "$version" ] && case "$version" in *"$expected"*) echo "$version"; return 0 ;; esac
    sleep 1
  done
  echo "--- /health unavailable on port $port after 150s; daemon log tail ---" >&2
  tail -n 5 "${home%/}/daemon.log" 2>/dev/null >&2 || true
  die "no /health reporting $expected on port $port"
}

scenario="${1:-}"
case "$scenario" in
  A|B|C)
    root="${2:?usage: $0 <A|B|C> <root> <port> [target-version]}"
    port="${3:?missing port}"
    target="${4:-$TARGET_VERSION}"
    require_systemd_user
    remove_unit
    rm -rf "$root"
    mkdir -p "$root/.sanad/bin"
    printf 'ENABLE_LOCAL_GATEWAY=true\nLOCAL_GATEWAY_PORT=%s\n' "$port" > "$root/.sanad/.env"

    case "$scenario" in
      A)
        download_agent "$OLD_VERSION" "$root/.sanad/bin/sanad"
        echo "PREP=A root=$root port=$port installed=$OLD_VERSION unit=absent"
        ;;
      B)
        download_agent "$OLD_VERSION" "$root/.sanad/bin/sanad"
        write_unit "$root/.sanad"
        systemctl --user start "$UNIT_NAME"
        echo "PREP=B root=$root port=$port installed=$OLD_VERSION unit=present health=$(wait_for_health "$root/.sanad" "$port" "$OLD_VERSION")"
        ;;
      C)
        download_agent "$target" "$root/.sanad/bin/sanad"
        # Unmanaged daemon: no service unit is registered for this Sanad Home.
        # setsid --fork plus full descriptor detach keeps the daemon alive after
        # this shell exits and stops it from holding the caller's stdout/stderr
        # open (otherwise an SSH or exec caller waits forever for EOF).
        setsid --fork bash -c 'cd "$1" && SANAD_HOME="$1" LOCAL_GATEWAY_PORT="$2" \
          exec ./bin/sanad daemon' _ "$root/.sanad" "$port" \
          > "$root/daemon.log" 2>&1 < /dev/null
        digest=$(wait_for_health "$root/.sanad" "$port" "$target")
        manual_pid="$(pgrep -f "$root/.sanad/bin/sanad daemon" | head -1 || true)"
        [ -n "$manual_pid" ] || die "could not determine the unmanaged daemon pid"
        echo "$manual_pid" > "$root/manual-daemon.pid"
        echo "PREP=C root=$root port=$port installed=$target unit=absent health=$digest"
        echo "TASK107_MANUAL_PID=$manual_pid"
        ;;
    esac
    ;;
  cleanup)
    root="${2:?usage: $0 cleanup <root> <port>}"
    remove_unit
    # Kill both the unmanaged supervisor and its child. Match on the resolved
    # executable path and working directory with any " (deleted)" suffix
    # stripped: the supervisor runs with a relative argv such as
    # `./bin/sanad daemon`, and a previous run's directory may already have been
    # removed while its daemon is still holding the port.
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$' || true); do
      exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"; exe="${exe% (deleted)}"
      cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"; cwd="${cwd% (deleted)}"
      case "$exe" in
        "$root/.sanad/bin/sanad") ;;
        *) case "$cwd" in "$root"/*) ;; *) continue ;; esac ;;
      esac
      kill "$pid" 2>/dev/null || true
    done
    rm -f "$root/manual-daemon.pid"
    echo "CLEANUP root=$root unit=removed linger=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)"
    ;;
  *)
    die "usage: $0 <A|B|C> <root> <port> [target-version] | $0 cleanup <root> <port>"
    ;;
esac
