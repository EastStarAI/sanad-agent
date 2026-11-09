#!/bin/sh
# Canonical Sanad Agent installer for macOS and Linux.

set -eu

REPOSITORY="EastStarAI/sanad-agent"
MANIFEST_URL="${SANAD_RELEASE_MANIFEST_URL:-https://github.com/$REPOSITORY/releases/latest/download/release-manifest.json}"
REQUESTED_SANAD_HOME="${SANAD_HOME:-}"
SYSTEM_SANAD_HOME="${SANAD_INSTALL_SYSTEM_HOME:-/var/lib/sanad-agent}"
SERVICE_NAME="sanad-agent.service"
SERVICE_BASE="sanad-agent"
CONFIG_ROOT="${SANAD_INSTALL_CONFIG_ROOT:-}"
RUN_AS_USER=""
RUN_AS_ARGS=""
PAIRING_TOKEN=""
PAIRING_TOKEN_STDIN=0
AUTH_MODE="prompt"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pairing-token)
      [ "$#" -ge 2 ] || {
        echo "Missing value for --pairing-token." >&2
        exit 64
      }
      PAIRING_TOKEN="$2"
      shift 2
      ;;
    --pairing-token-stdin)
      PAIRING_TOKEN_STDIN=1
      shift
      ;;
    --run-as-user)
      [ "$#" -ge 2 ] || {
        echo "Missing value for --run-as-user." >&2
        exit 64
      }
      RUN_AS_USER="$2"
      shift 2
      ;;
    --login)
      if [ "$AUTH_MODE" = "skip" ]; then
        echo "Choose either --login or --no-login, not both." >&2
        exit 64
      fi
      AUTH_MODE="login"
      shift
      ;;
    --no-login)
      if [ "$AUTH_MODE" = "login" ]; then
        echo "Choose either --login or --no-login, not both." >&2
        exit 64
      fi
      AUTH_MODE="skip"
      shift
      ;;
    *)
      echo "Unknown installer argument." >&2
      exit 64
      ;;
  esac
done

if [ "$PAIRING_TOKEN_STDIN" -eq 1 ]; then
  [ -z "$PAIRING_TOKEN" ] || {
    echo "Choose one pairing-token input method." >&2
    exit 64
  }
  IFS= read -r PAIRING_TOKEN || true
  [ -n "$PAIRING_TOKEN" ] || {
    echo "Pairing token stdin was empty." >&2
    exit 64
  }
fi

if [ -n "$PAIRING_TOKEN" ] && [ "$AUTH_MODE" != "prompt" ]; then
  echo "--pairing-token cannot be combined with --login or --no-login." >&2
  exit 64
fi

case "$MANIFEST_URL" in
  https://github.com/EastStarAI/sanad-agent/*) ;;
  *)
    if [ "${SANAD_INSTALL_ALLOW_TEST_URL:-0}" != "1" ]; then
      echo "Refusing an untrusted release manifest URL." >&2
      exit 65
    fi
    ;;
esac

OS_NAME="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS_NAME" in
  darwin) PLATFORM="macos" ;;
  linux) PLATFORM="linux" ;;
  *)
    echo "Unsupported operating system: $OS_NAME" >&2
    exit 69
    ;;
esac

# The account and Home a Linux system unit uses, mirroring the Agent's
# `SystemServiceAccount` policy: a root install (direct or entered through sudo)
# runs the unit as the dedicated unprivileged `sanad-agent` account and keeps the
# artifact in that account's Home, because `/root` is 0700 and systemd otherwise
# fails the unit with 203/EXEC after pairing already succeeded. `SUDO_USER`
# never selects the account; `--run-as-user` is the one explicit override.
account_home() {
  getent passwd "$1" 2>/dev/null | cut -d: -f6
}

if [ -n "$RUN_AS_USER" ]; then
  if [ "$PLATFORM" != "linux" ]; then
    echo "--run-as-user is only supported for Linux services." >&2
    exit 69
  fi
  if [ "$(id -u)" -ne 0 ]; then
    echo "--run-as-user requires a root installation; run it with sudo." >&2
    exit 77
  fi
  RUN_AS_HOME="$(account_home "$RUN_AS_USER")"
  if [ -z "$RUN_AS_HOME" ]; then
    echo "Account \"$RUN_AS_USER\" does not exist." >&2
    exit 64
  fi
fi

# An explicit retrieval of root's own Home: plain `sudo` may leave `HOME`
# pointing at the invoking account, and that account's Home is not where the
# dedicated service account can run the Agent.
if [ -n "$REQUESTED_SANAD_HOME" ]; then
  SANAD_USER_HOME="$REQUESTED_SANAD_HOME"
elif [ -n "$RUN_AS_USER" ]; then
  SANAD_USER_HOME="$RUN_AS_HOME/.sanad"
elif [ "$PLATFORM" = "linux" ] && [ "$(id -u)" -eq 0 ] &&
  [ ! -x "$(account_home root)/.sanad/bin/sanad" ]; then
  SANAD_USER_HOME="$SYSTEM_SANAD_HOME"
  echo "Root install: using $SANAD_USER_HOME as the Sanad Home so the dedicated service account can run the Agent."
else
  SANAD_USER_HOME="$HOME/.sanad"
fi
# The Agent resolves its Home from this variable, so the installed binary, the
# daemon the unit starts, and this installer must all select the same one.
SANAD_HOME="$SANAD_USER_HOME"
export SANAD_HOME
BIN_DIR="$SANAD_USER_HOME/bin"
TARGET="$BIN_DIR/sanad"
BACKUP="$TARGET.rollback"

if [ -n "$RUN_AS_USER" ]; then
  echo "The Sanad Agent service will run as $RUN_AS_USER with $SANAD_USER_HOME."
  # The account is a validated passwd name, so it is appended as one option.
  RUN_AS_ARGS="--run-as-user $RUN_AS_USER"
  if [ "$RUN_AS_USER" = "root" ]; then
    echo "Warning: the Agent daemon will run as root, so every Agent tool, MCP server, and terminal task inherits root privileges." >&2
  fi
fi

existing_definition() {
  for candidate in \
    "$CONFIG_ROOT/etc/systemd/system/$SERVICE_NAME" \
    "$CONFIG_ROOT/etc/init.d/$SERVICE_BASE"; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

definition_home() {
  sed -n 's/^Environment="SANAD_HOME=\(.*\)"$/\1/p' "$1"
  sed -n "s/^export SANAD_HOME='\(.*\)'$/\1/p" "$1"
}

# A definition registered for another Home cannot be upgraded in place: the
# Agent would refuse it as a conflicting service after the download and the
# device authorization. Refuse first, with the exact command that removes it.
DEFINITION="$(existing_definition || true)"
if [ -n "$DEFINITION" ]; then
  DEFINITION_HOME="$(definition_home "$DEFINITION" |
    head -n 1 |
    sed -e 's/\\x20/ /g' -e 's/%%/%/g')"
  if [ -n "$DEFINITION_HOME" ] && [ "$DEFINITION_HOME" != "$SANAD_USER_HOME" ]; then
    echo "An existing Sanad service is registered for another Sanad Home:" >&2
    echo "  definition: $DEFINITION" >&2
    echo "  home:       $DEFINITION_HOME" >&2
    echo "This install would use $SANAD_USER_HOME. Remove the existing service first:" >&2
    if [ -x "$DEFINITION_HOME/bin/sanad" ]; then
      echo "  SANAD_HOME='$DEFINITION_HOME' '$DEFINITION_HOME/bin/sanad' service uninstall" >&2
    fi
    case "$DEFINITION" in
      /etc/init.d/*)
        echo "  rc-update del $SERVICE_BASE default && rm -f '$DEFINITION'" >&2
        ;;
      *)
        echo "  systemctl disable --now $SERVICE_NAME && rm -f '$DEFINITION'" >&2
        ;;
    esac
    exit 71
  fi
fi

# The definition this installer writes, with the one explicit account override.

# The Agent runs the unit as an account that did not create the Home, so that
# account must own the artifact and the credentials pairing wrote under it.
ensure_run_as_ownership() {
  [ -n "$RUN_AS_USER" ] && [ "$RUN_AS_USER" != "root" ] || return 0
  chown -R "$RUN_AS_USER" "$SANAD_USER_HOME"
}

if [ "$PLATFORM" = "linux" ]; then
  [ ! -L "$SANAD_USER_HOME" ] || {
    echo "Refusing a symlinked SANAD_HOME." >&2
    exit 73
  }
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    if systemctl --user show-environment >/dev/null 2>&1 &&
      [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)" = "yes" ]; then
      :
    elif [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
      echo "System service fallback requires root or sudo." >&2
      exit 77
    fi
  elif command -v rc-service >/dev/null 2>&1 &&
    command -v rc-update >/dev/null 2>&1; then
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
      echo "OpenRC service installation requires root or sudo." >&2
      exit 77
    fi
  else
    echo "Unsupported Linux init manager; systemd or OpenRC is required." >&2
    exit 69
  fi
fi

SERVICE_WAS_INSTALLED=0
SERVICE_WAS_RUNNING=0
PREVIOUS_AUTHENTICATED=0
if [ -x "$TARGET" ]; then
  PREVIOUS_SERVICE_STATUS="$("$TARGET" service status 2>/dev/null || true)"
  printf '%s\n' "$PREVIOUS_SERVICE_STATUS" | grep -Fq 'Installed:  Yes' &&
    SERVICE_WAS_INSTALLED=1
  printf '%s\n' "$PREVIOUS_SERVICE_STATUS" | grep -Fq 'Running:    Yes' &&
    SERVICE_WAS_RUNNING=1
  PREVIOUS_AUTH_STATUS="$("$TARGET" login --status 2>/dev/null || true)"
  printf '%s\n' "$PREVIOUS_AUTH_STATUS" | grep -Fq 'Status: Authenticated' &&
    PREVIOUS_AUTHENTICATED=1
fi

case "$(uname -m)" in
  arm64|aarch64) ARCHITECTURE="arm64" ;;
  x86_64|amd64) ARCHITECTURE="x64" ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 69
    ;;
esac

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sanad-install.XXXXXX")"
cleanup() {
  find "$TEMP_DIR" -type f -exec chmod 600 {} \; 2>/dev/null || true
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

download() {
  source_url="$1"
  destination="$2"
  if command -v curl >/dev/null 2>&1; then
    if [ "${SANAD_INSTALL_ALLOW_TEST_URL:-0}" = "1" ]; then
      curl --fail --silent --show-error --location \
        --output "$destination" "$source_url"
    else
      curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --output "$destination" "$source_url"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ "${SANAD_INSTALL_ALLOW_TEST_URL:-0}" = "1" ]; then
      wget --quiet --output-document="$destination" "$source_url"
    else
      wget --https-only --quiet --output-document="$destination" "$source_url"
    fi
  else
    echo "Install curl or wget, then retry." >&2
    exit 69
  fi
}

download "$MANIFEST_URL" "$TEMP_DIR/release-manifest.json"

# Select the one public Agent asset this machine can run.
#
# The selector prints the five manifest fields on success and one actionable
# diagnosis on failure, so an architecture this release does not publish ends
# with a named reason instead of a silent stop. A wrong target is never
# substituted with another one: a mismatched binary is worse than no install.
select_agent_metadata() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$TEMP_DIR/release-manifest.json" "$PLATFORM" "$ARCHITECTURE" <<'PY'
import json, sys

path, platform, architecture = sys.argv[1:]
target = platform + "/" + architecture


def fail(exit_code, message):
    print(message)
    sys.exit(exit_code)


try:
    with open(path, encoding="utf-8") as stream:
        manifest = json.load(stream)
except (OSError, ValueError) as error:
    fail(65, "Release manifest could not be read: %s" % error)
if not isinstance(manifest, dict):
    fail(65, "Release manifest must be a JSON object.")
if manifest.get("repository") != "EastStarAI/sanad-agent":
    fail(65, "Release manifest repository is not trusted: %s" % manifest.get("repository"))
version = manifest.get("version", "this release")
agents = [
    item for item in (manifest.get("artifacts") or [])
    if isinstance(item, dict)
    and item.get("component") == "agent"
    and item.get("public") is True
    and item.get("signature_type")
]
matches = [
    item for item in agents
    if item.get("platform") == platform and item.get("architecture") == architecture
]
if not matches:
    published = sorted({str(item.get("platform")) + "/" + str(item.get("architecture")) for item in agents})
    fail(
        69,
        "No official Sanad Agent build is published for %s in %s. "
        "Published Agent targets: %s. Install on a supported target, or wait for "
        "a release that publishes this one." % (target, version, ", ".join(published) or "none"),
    )
if len(matches) != 1:
    fail(65, "Release manifest is ambiguous: %d public Agent assets for %s." % (len(matches), target))
item = matches[0]
runtimes = [
    entry for entry in manifest.get("artifacts", [])
    if entry.get("component") == "agent-runtime"
    and entry.get("platform") == platform
    and entry.get("architecture") == architecture
    and entry.get("public") is True
    and entry.get("format") == "tar.gz"
]
if len(runtimes) > 1:
    raise SystemExit("manifest declares more than one matching agent runtime")
runtime = runtimes[0] if runtimes else None
print(item["filename"])
print(item["url"])
print(item["sha256"])
print(item["size"])
print(version)
print("" if runtime is None else runtime["filename"])
print("" if runtime is None else runtime["url"])
print("" if runtime is None else runtime["sha256"])
print("" if runtime is None else runtime["size"])
PY
  elif [ "$PLATFORM" = "macos" ] && command -v osascript >/dev/null 2>&1; then
    osascript -l JavaScript "$TEMP_DIR/release-manifest.json" "$PLATFORM" "$ARCHITECTURE" <<'JXA'
ObjC.import('Foundation')
const args = $.NSProcessInfo.processInfo.arguments.js.slice(4)
const data = $.NSData.dataWithContentsOfFile(args[0])
const text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js
const manifest = JSON.parse(text)
const target = args[1] + '/' + args[2]
if (manifest.repository !== 'EastStarAI/sanad-agent') {
  throw new Error('Release manifest repository is not trusted: ' + manifest.repository)
}
const agents = (manifest.artifacts || []).filter(
  item => item.component === 'agent' &&
    item.public === true &&
    Boolean(item.signature_type)
)
const published = [...new Set(agents.map(item => item.platform + '/' + item.architecture))].sort()
const matches = agents.filter(
  item => item.platform === args[1] && item.architecture === args[2]
)
if (matches.length === 0) {
  throw new Error(
    'No official Sanad Agent build is published for ' + target +
      ' in ' + manifest.version + '. Published Agent targets: ' +
      (published.length ? published.join(', ') : 'none') + '.'
  )
}
if (matches.length !== 1) {
  throw new Error('Release manifest is ambiguous: ' + matches.length +
    ' public Agent assets for ' + target + '.')
}
const item = matches[0]
const runtimes = manifest.artifacts.filter(
  entry => entry.component === 'agent-runtime' &&
    entry.platform === args[1] &&
    entry.architecture === args[2] &&
    entry.public === true &&
    entry.format === 'tar.gz'
)
if (runtimes.length > 1) throw new Error('multiple matching agent runtimes')
const runtime = runtimes.length === 1 ? runtimes[0] : null
[
  item.filename, item.url, item.sha256, item.size, manifest.version,
  runtime ? runtime.filename : '',
  runtime ? runtime.url : '',
  runtime ? runtime.sha256 : '',
  runtime ? runtime.size : ''
].join('\n')
JXA
  else
    echo "Python 3 is required on Linux to validate the release manifest." >&2
    return 69
  fi
}

SELECTION_FILE="$TEMP_DIR/agent-selection"
SELECTION_STATUS=0
select_agent_metadata >"$SELECTION_FILE" || SELECTION_STATUS=$?
if [ "$SELECTION_STATUS" -ne 0 ]; then
  if [ -s "$SELECTION_FILE" ]; then
    cat "$SELECTION_FILE" >&2
  else
    echo "No official Sanad Agent build was selected for $PLATFORM/$ARCHITECTURE." >&2
  fi
  exit "$SELECTION_STATUS"
fi
METADATA="$(cat "$SELECTION_FILE")"

FILENAME="$(printf '%s\n' "$METADATA" | sed -n '1p')"
DOWNLOAD_URL="$(printf '%s\n' "$METADATA" | sed -n '2p')"
EXPECTED_SHA256="$(printf '%s\n' "$METADATA" | sed -n '3p')"
EXPECTED_SIZE="$(printf '%s\n' "$METADATA" | sed -n '4p')"
EXPECTED_VERSION="$(printf '%s\n' "$METADATA" | sed -n '5p')"
[ -n "$EXPECTED_VERSION" ] || {
  echo "Manifest returned an invalid version." >&2
  exit 65
}
# The packaged Agent carries its native dictation runtime beside the executable.
# The manifest names that archive; an older release that predates it simply has
# no such entry and installs the executable alone.
RUNTIME_FILENAME="$(printf '%s\n' "$METADATA" | sed -n '6p')"
RUNTIME_URL="$(printf '%s\n' "$METADATA" | sed -n '7p')"
RUNTIME_SHA256="$(printf '%s\n' "$METADATA" | sed -n '8p')"
RUNTIME_SIZE="$(printf '%s\n' "$METADATA" | sed -n '9p')"
RUNTIME_TAG="$PLATFORM-$ARCHITECTURE"
RUNTIME_PRESENT=0
if [ -n "$RUNTIME_FILENAME" ]; then
  case "$RUNTIME_FILENAME" in
    sanad-agent-runtime-*-"$RUNTIME_TAG".tar.gz) RUNTIME_PRESENT=1 ;;
    *)
      echo "Manifest returned an invalid native runtime filename." >&2
      exit 65
      ;;
  esac
  if [ -z "$RUNTIME_SHA256" ] || [ -z "$RUNTIME_SIZE" ]; then
    echo "Manifest returned incomplete native runtime metadata." >&2
    exit 65
  fi
  case "$RUNTIME_URL" in
    https://github.com/EastStarAI/sanad-agent/releases/download/*/"$RUNTIME_FILENAME") ;;
    *)
      if [ "${SANAD_INSTALL_ALLOW_TEST_URL:-0}" != "1" ]; then
        echo "Manifest returned an untrusted native runtime URL." >&2
        exit 65
      fi
      ;;
  esac
fi

case "$FILENAME" in
  sanad-agent-*-"$PLATFORM"-"$ARCHITECTURE") ;;
  *)
    echo "Manifest returned an invalid filename." >&2
    exit 65
    ;;
esac
case "$DOWNLOAD_URL" in
  https://github.com/EastStarAI/sanad-agent/releases/download/*/"$FILENAME") ;;
  *)
    if [ "${SANAD_INSTALL_ALLOW_TEST_URL:-0}" != "1" ]; then
      echo "Manifest returned an untrusted download URL." >&2
      exit 65
    fi
    ;;
esac

STAGED="$TEMP_DIR/$FILENAME"
download "$DOWNLOAD_URL" "$STAGED"
ACTUAL_SIZE="$(wc -c < "$STAGED" | tr -d ' ')"
if [ "$ACTUAL_SIZE" != "$EXPECTED_SIZE" ]; then
  echo "Downloaded artifact size verification failed." >&2
  exit 66
fi
if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(shasum -a 256 "$STAGED" | awk '{print $1}')"
else
  ACTUAL_SHA256="$(sha256sum "$STAGED" | awk '{print $1}')"
fi
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "Downloaded artifact SHA-256 verification failed." >&2
  exit 66
fi
if [ "$PLATFORM" = "macos" ]; then
  MACOS_AGENT_PUBLISHER_REQUIREMENT='=anchor apple generic and certificate leaf[subject.OU] = "UC2824B99G" and certificate leaf[subject.CN] = "Developer ID Application: NanoSoft LY LLC (UC2824B99G)"'
  if ! codesign --verify --strict --verbose=2 \
    --test-requirement "$MACOS_AGENT_PUBLISHER_REQUIREMENT" "$STAGED"; then
    echo "Downloaded artifact publisher signature is not trusted." >&2
    exit 66
  fi
fi

PAIRING_PREPARED=0
RUNTIME_DIR="$BIN_DIR/native/$RUNTIME_TAG"
RUNTIME_BACKUP="$RUNTIME_DIR.rollback"
RUNTIME_REPLACED=0
ROLLBACK_INCOMPLETE=0
# The packaged runtime is a dictation companion, not part of the Agent contract:
# a failure to fetch or verify it disables dictation only and never fails the
# install. The reason is recorded beside the runtime so the daemon's dictation
# readiness can name it until a later install or update succeeds.
RUNTIME_FAILURE_MARKER="$BIN_DIR/native/.runtime-install-failed"
record_runtime_failure() {
  mkdir -p "$BIN_DIR/native" 2>/dev/null || true
  printf '%s\n' "$1" > "$RUNTIME_FAILURE_MARKER" 2>/dev/null || true
}
clear_runtime_failure() {
  rm -f "$RUNTIME_FAILURE_MARKER" 2>/dev/null || true
}
restore_previous_installation() {
  if [ "$PAIRING_PREPARED" -eq 1 ] && [ -x "$TARGET" ]; then
    "$TARGET" login --cancel-pairing >/dev/null 2>&1 || true
  fi
  if [ "$SERVICE_WAS_INSTALLED" -eq 0 ] && [ -x "$TARGET" ]; then
    "$TARGET" service uninstall >/dev/null 2>&1 || true
  fi
  rm -f "$TARGET"
  if [ -f "$BACKUP" ]; then
    if ! mv "$BACKUP" "$TARGET"; then
      # The previous executable is still in $BACKUP; never report a clean
      # rollback for a restore that did not happen.
      ROLLBACK_INCOMPLETE=1
    fi
  fi
  if [ "$RUNTIME_REPLACED" -eq 1 ]; then
    if ! rm -rf "$RUNTIME_DIR"; then
      # Keep the predecessor backup: a move into a directory that could not be
      # cleared would nest it and bury the only copy.
      ROLLBACK_INCOMPLETE=1
    elif [ -d "$RUNTIME_BACKUP" ]; then
      if ! mv "$RUNTIME_BACKUP" "$RUNTIME_DIR"; then
        # The backup is the only copy of the previous runtime; keep it there.
        ROLLBACK_INCOMPLETE=1
      fi
    else
      # The backup this run created is gone, so the replaced runtime cannot be
      # restored; do not report a clean rollback either.
      ROLLBACK_INCOMPLETE=1
    fi
  elif [ "$RUNTIME_REPLACED" -eq 2 ]; then
    # No runtime existed before this run, so removing ours restores the
    # previous state instead of leaving dictation half installed.
    if ! rm -rf "$RUNTIME_DIR"; then
      ROLLBACK_INCOMPLETE=1
    fi
  fi
  RUNTIME_REPLACED=0
  if [ "$SERVICE_WAS_RUNNING" -eq 1 ] && [ -x "$TARGET" ]; then
    "$TARGET" service start >/dev/null 2>&1 || true
  fi
}

# Reports a failed step after one rollback pass, with the truthful outcome.
# A restore that failed keeps its backup on disk and says so; this function is
# the only place that prints the rollback sentence, so no path can claim a
# completed rollback that did not happen.
fail_installation() {
  restore_previous_installation
  if [ "$ROLLBACK_INCOMPLETE" -eq 1 ]; then
    echo "$1; the previous installation could not be fully restored. Recovery files remain beside $TARGET and $RUNTIME_DIR (*.rollback)." >&2
  else
    echo "$1; installation rollback completed." >&2
  fi
  exit "$2"
}

# Places the verified runtime in `<home>/bin/native/<tag>/`, the first location
# the loader searches relative to the installed executable. Size and SHA-256
# come from the release manifest; the extracted tree is then checked for the
# expected layout and for any file outside the library allowlist, so a wrong or
# hostile archive cannot scatter files next to the Agent.
install_native_runtime() {
  [ "$RUNTIME_PRESENT" -eq 1 ] || return 0
  if ! command -v tar >/dev/null 2>&1; then
    if [ -d "$RUNTIME_DIR" ]; then
      echo "tar is required to install the native dictation runtime; keeping the runtime already installed in $RUNTIME_DIR." >&2
    else
      echo "tar is required to install the native dictation runtime; dictation stays unavailable." >&2
    fi
    return 0
  fi
  runtime_archive="$TEMP_DIR/$RUNTIME_FILENAME"
  download "$RUNTIME_URL" "$runtime_archive"
  runtime_size="$(wc -c < "$runtime_archive" | tr -d ' ')"
  if [ "$runtime_size" != "$RUNTIME_SIZE" ]; then
    echo "Native runtime size verification failed." >&2
    return 1
  fi
  if command -v shasum >/dev/null 2>&1; then
    runtime_sha="$(shasum -a 256 "$runtime_archive" | awk '{print $1}')"
  else
    runtime_sha="$(sha256sum "$runtime_archive" | awk '{print $1}')"
  fi
  if [ "$runtime_sha" != "$RUNTIME_SHA256" ]; then
    echo "Native runtime SHA-256 verification failed." >&2
    return 1
  fi
  extract="$TEMP_DIR/runtime"
  mkdir -p "$extract"
  if ! tar -xzf "$runtime_archive" -C "$extract" --no-same-owner \
    --no-same-permissions 2>/dev/null; then
    if ! tar -xzf "$runtime_archive" -C "$extract"; then
      echo "Native runtime extraction failed." >&2
      return 1
    fi
  fi
  expected="$extract/native/$RUNTIME_TAG"
  if [ ! -d "$expected" ]; then
    echo "Native runtime archive has an unexpected layout." >&2
    return 1
  fi
  for entry in "$extract"/native/*; do
    if [ "$entry" != "$expected" ]; then
      echo "Native runtime archive has an unexpected layout." >&2
      return 1
    fi
  done
  if find "$expected" -type d -mindepth 1 \
    ! -path "$expected/sherpa" \
    ! -path "$expected/sherpa/sherpa_onnx_macos" \
    ! -path "$expected/sherpa/sherpa_onnx_macos/sherpa-onnx.xcframework" \
    ! -path "$expected/sherpa/sherpa_onnx_macos/sherpa-onnx.xcframework/macos-arm64_x86_64" \
    | grep -q .; then
    echo "Native runtime archive has an unexpected layout." >&2
    return 1
  fi
  if find "$extract" -name '.*' | grep -q .; then
    echo "Native runtime archive contains a hidden entry." >&2
    return 1
  fi
  # Directories are allowed only where the layout check above accepted them;
  # anything that is neither a file nor a directory (a link, a socket, a device)
  # is still refused.
  if find "$expected" -mindepth 1 ! -type f ! -type d | grep -q .; then
    echo "Native runtime archive contains an entry that is not a regular file." >&2
    return 1
  fi
  if find "$expected" -type f ! -name '*.dylib' ! -name '*.so' \
    ! -name '*.so.*' ! -name '*.dll' | grep -q .; then
    echo "Native runtime archive contains a file outside the library allowlist." >&2
    return 1
  fi
  find "$expected" -type f -exec chmod 755 {} \;
  chmod 755 "$expected"
  mkdir -p "$BIN_DIR/native"
  if [ -d "$RUNTIME_DIR" ]; then
    if [ -e "$RUNTIME_BACKUP" ]; then
      rm -rf "$RUNTIME_BACKUP"
    fi
    if [ -e "$RUNTIME_BACKUP" ]; then
      # `mv` would otherwise move the old directory *into* this stale one.
      echo "Unable to clear the stale native runtime backup beside the Agent." >&2
      return 1
    fi
    if ! mv "$RUNTIME_DIR" "$RUNTIME_BACKUP"; then
      echo "Unable to replace the installed native runtime." >&2
      return 1
    fi
    RUNTIME_REPLACED=1
  else
    RUNTIME_REPLACED=2
  fi
  if ! mv "$expected" "$RUNTIME_DIR"; then
    # Leave the backup where it is: the caller's single rollback pass moves it
    # back, and that pass is also what reports a restore that failed.
    echo "Unable to install the native runtime beside the Agent." >&2
    return 1
  fi
  # The backup lives until the whole installation transaction commits: a later
  # pairing, sign-in, ownership, or service failure must be able to restore the
  # runtime this run replaced.
  return 0
}

if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
  if ! "$TARGET" service stop; then
    echo "Unable to stop the existing service; no files were replaced." >&2
    exit 70
  fi
fi

mkdir -p "$BIN_DIR" "$SANAD_USER_HOME/logs"
chmod 700 "$SANAD_USER_HOME" "$BIN_DIR"
chmod 700 "$STAGED"
if [ -f "$BACKUP" ]; then rm -f "$BACKUP"; fi
if [ -f "$TARGET" ]; then mv "$TARGET" "$BACKUP"; fi
if ! mv "$STAGED" "$TARGET"; then
  fail_installation "Unable to install the verified executable" 74
fi
RUNTIME_FAILED=0
if ! install_native_runtime; then
  # The Agent is already verified and in place; only dictation is lost, so the
  # installation continues and the reason stays visible in readiness.
  RUNTIME_FAILED=1
  if [ "$RUNTIME_REPLACED" -eq 1 ] && [ -d "$RUNTIME_BACKUP" ] &&
    [ ! -d "$RUNTIME_DIR" ]; then
    # This run moved the predecessor aside and could not install its successor:
    # restore it so a transient failure never costs a working runtime.
    mv "$RUNTIME_BACKUP" "$RUNTIME_DIR" || true
  fi
  RUNTIME_REPLACED=0
  record_runtime_failure "runtime_install_failed"
  echo "Native dictation runtime installation failed; the Agent is installed and runs, and dictation stays unavailable until the next install or update re-fetches it." >&2
else
  clear_runtime_failure
fi
if [ "$RUNTIME_PRESENT" -eq 0 ]; then
  if [ -d "$RUNTIME_DIR" ]; then
    echo "This release publishes no native dictation runtime for $RUNTIME_TAG; keeping the runtime already installed in $RUNTIME_DIR." >&2
  else
    echo "This release publishes no native dictation runtime for $RUNTIME_TAG and none is installed; dictation stays unavailable." >&2
  fi
fi

PORTAL_LOGIN=0
if [ -n "$PAIRING_TOKEN" ]; then
  if ! printf '%s\n' "$PAIRING_TOKEN" | "$TARGET" login --token-stdin; then
    fail_installation "Device pairing setup failed" 70
  fi
  PAIRING_PREPARED=1
elif [ "$AUTH_MODE" = "login" ]; then
  PORTAL_LOGIN=1
elif [ "$AUTH_MODE" = "prompt" ] && [ -r /dev/tty ] && [ -w /dev/tty ] &&
  (exec 3<>/dev/tty) 2>/dev/null; then
  while :; do
    printf 'Connect this device to your Sanad account now? [Y/n]: ' >/dev/tty
    if ! IFS= read -r LOGIN_RESPONSE </dev/tty; then
      LOGIN_RESPONSE="n"
    fi
    case "$LOGIN_RESPONSE" in
      ""|y|Y|yes|YES|Yes)
        PORTAL_LOGIN=1
        break
        ;;
      n|N|no|NO|No)
        break
        ;;
      *)
        echo "Please answer yes or no." >/dev/tty
        ;;
    esac
  done
elif [ "$AUTH_MODE" = "prompt" ]; then
  echo "No interactive terminal detected; continuing in local-only mode."
fi

if [ "$PORTAL_LOGIN" -eq 1 ]; then
  if ! "$TARGET" login --portal; then
    fail_installation "Account sign-in failed" 70
  fi
fi

if ! ensure_run_as_ownership; then
  fail_installation "Unable to give $RUN_AS_USER ownership of $SANAD_USER_HOME" 74
fi

if [ -n "$PAIRING_TOKEN" ] || [ "$PORTAL_LOGIN" -eq 1 ] ||
  [ "$PREVIOUS_AUTHENTICATED" -eq 1 ]; then
  if ! "$TARGET" service install --expected-version "$EXPECTED_VERSION" \
    --require-cloud --health-timeout 90 $RUN_AS_ARGS; then
    if [ -n "$PAIRING_TOKEN" ] || [ "$PORTAL_LOGIN" -eq 1 ]; then
      echo "This attempt already authorized the device; a retry needs a fresh pairing code or a new Portal approval." >&2
    fi
    fail_installation "Service or cloud health verification failed" 70
  fi
else
  if ! "$TARGET" service install --expected-version "$EXPECTED_VERSION" \
    --health-timeout 60 $RUN_AS_ARGS; then
    fail_installation "Service health verification failed" 70
  fi
fi

# Commit: the new executable already runs and the whole transaction succeeded,
# so this is the first moment both backups are disposable.
rm -f "$BACKUP"
if [ -d "$RUNTIME_BACKUP" ]; then
  if [ "$RUNTIME_FAILED" -eq 1 ]; then
    # The predecessor runtime could not be restored; it is the only copy left.
    echo "The previous native runtime is kept at $RUNTIME_BACKUP." >&2
  else
    rm -rf "$RUNTIME_BACKUP"
  fi
fi
echo "Sanad Agent installed successfully."
if [ -n "$PAIRING_TOKEN" ]; then
  echo "Device pairing completed and the Agent is online."
elif [ "$PORTAL_LOGIN" -eq 1 ]; then
  echo "Account connected. Sanad Agent is running in the background."
elif [ "$PREVIOUS_AUTHENTICATED" -eq 1 ]; then
  echo "Existing account connection restored. Sanad Agent is online."
else
  echo "Sanad Agent is running in local-only mode."
  echo "Connect it later with:"
  echo "  $TARGET login"
  echo "  $TARGET service restart"
fi
