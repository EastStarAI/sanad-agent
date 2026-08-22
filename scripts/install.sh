#!/bin/sh
# Canonical Sanad Agent installer for macOS and Linux.

set -eu

REPOSITORY="EastStarAI/sanad-agent"
MANIFEST_URL="${SANAD_RELEASE_MANIFEST_URL:-https://github.com/$REPOSITORY/releases/latest/download/release-manifest.json}"
SANAD_USER_HOME="${SANAD_HOME:-$HOME/.sanad}"
BIN_DIR="$SANAD_USER_HOME/bin"
TARGET="$BIN_DIR/sanad"
BACKUP="$TARGET.rollback"
PAIRING_TOKEN=""
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

SERVICE_WAS_INSTALLED=0
SERVICE_WAS_RUNNING=0
if [ "$PLATFORM" = "macos" ]; then
  [ -f "$HOME/Library/LaunchAgents/com.eaststarai.sanad.agent.plist" ] &&
    SERVICE_WAS_INSTALLED=1
  if [ "$SERVICE_WAS_INSTALLED" -eq 1 ] &&
    launchctl list 2>/dev/null | grep -Fq 'com.eaststarai.sanad.agent'; then
    SERVICE_WAS_RUNNING=1
  fi
else
  [ -f "$HOME/.config/systemd/user/sanad-agent.service" ] &&
    SERVICE_WAS_INSTALLED=1
  if [ "$SERVICE_WAS_INSTALLED" -eq 1 ] &&
    systemctl --user is-active --quiet sanad-agent.service 2>/dev/null; then
    SERVICE_WAS_RUNNING=1
  fi
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
    curl --fail --silent --show-error --location \
      --proto '=https' --tlsv1.2 \
      --output "$destination" "$source_url"
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only --quiet --output-document="$destination" "$source_url"
  else
    echo "Install curl or wget, then retry." >&2
    exit 69
  fi
}

download "$MANIFEST_URL" "$TEMP_DIR/release-manifest.json"

if command -v python3 >/dev/null 2>&1; then
  METADATA="$(python3 - "$TEMP_DIR/release-manifest.json" "$PLATFORM" "$ARCHITECTURE" <<'PY'
import json, sys
path, platform, architecture = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    manifest = json.load(stream)
if manifest.get("repository") != "EastStarAI/sanad-agent":
    raise SystemExit("manifest repository is not trusted")
matches = [
    item for item in manifest.get("artifacts", [])
    if item.get("component") == "agent"
    and item.get("platform") == platform
    and item.get("architecture") == architecture
    and item.get("public") is True
    and item.get("signature_type")
]
if len(matches) != 1:
    raise SystemExit("manifest does not contain exactly one matching agent")
item = matches[0]
print(item["filename"])
print(item["url"])
print(item["sha256"])
print(item["size"])
PY
)"
elif [ "$PLATFORM" = "macos" ] && command -v osascript >/dev/null 2>&1; then
  METADATA="$(osascript -l JavaScript "$TEMP_DIR/release-manifest.json" "$PLATFORM" "$ARCHITECTURE" <<'JXA'
ObjC.import('Foundation')
const args = $.NSProcessInfo.processInfo.arguments.js.slice(4)
const data = $.NSData.dataWithContentsOfFile(args[0])
const text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js
const manifest = JSON.parse(text)
if (manifest.repository !== 'EastStarAI/sanad-agent') {
  throw new Error('manifest repository is not trusted')
}
const matches = manifest.artifacts.filter(
  item => item.component === 'agent' &&
    item.platform === args[1] &&
    item.architecture === args[2] &&
    item.public === true &&
    Boolean(item.signature_type)
)
if (matches.length !== 1) throw new Error('missing matching agent')
const item = matches[0]
[item.filename, item.url, item.sha256, item.size].join('\n')
JXA
)"
else
  echo "Python 3 is required on Linux to validate the release manifest." >&2
  exit 69
fi

FILENAME="$(printf '%s\n' "$METADATA" | sed -n '1p')"
DOWNLOAD_URL="$(printf '%s\n' "$METADATA" | sed -n '2p')"
EXPECTED_SHA256="$(printf '%s\n' "$METADATA" | sed -n '3p')"
EXPECTED_SIZE="$(printf '%s\n' "$METADATA" | sed -n '4p')"

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

mkdir -p "$BIN_DIR" "$SANAD_USER_HOME/logs"
chmod 700 "$SANAD_USER_HOME" "$BIN_DIR"
chmod 700 "$STAGED"
if [ -f "$BACKUP" ]; then rm -f "$BACKUP"; fi
if [ -f "$TARGET" ]; then mv "$TARGET" "$BACKUP"; fi
if ! mv "$STAGED" "$TARGET"; then
  [ -f "$BACKUP" ] && mv "$BACKUP" "$TARGET"
  echo "Unable to install the verified executable; rollback completed." >&2
  exit 74
fi

PORTAL_LOGIN=0
if [ -n "$PAIRING_TOKEN" ]; then
  if ! "$TARGET" login --token "$PAIRING_TOKEN"; then
    rm -f "$TARGET"
    [ -f "$BACKUP" ] && mv "$BACKUP" "$TARGET"
    echo "Device pairing setup failed; installation rollback completed." >&2
    exit 70
  fi
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
    rm -f "$TARGET"
    [ -f "$BACKUP" ] && mv "$BACKUP" "$TARGET"
    echo "Account sign-in failed; installation rollback completed." >&2
    exit 70
  fi
fi

if ! "$TARGET" service install; then
  rm -f "$TARGET"
  [ -f "$BACKUP" ] && mv "$BACKUP" "$TARGET"
  echo "Service installation failed; rollback completed." >&2
  exit 70
fi

if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
  if ! "$TARGET" service restart; then
    echo "The agent was installed, but the existing service could not be refreshed." >&2
    exit 70
  fi
fi

echo "Sanad Agent installed successfully."
if [ -n "$PAIRING_TOKEN" ]; then
  echo "Device pairing started. Sanad will appear online automatically."
elif [ "$PORTAL_LOGIN" -eq 1 ]; then
  echo "Account connected. Sanad Agent is running in the background."
else
  echo "Sanad Agent is running in local-only mode."
  echo "Connect it later with:"
  echo "  $TARGET login"
  echo "  $TARGET service restart"
fi
