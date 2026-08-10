#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
temporary="$(mktemp -d)"
cleanup() { rm -rf "$temporary"; }
trap cleanup EXIT HUP INT TERM

cat > "$temporary/ssh" <<'SSH'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$SANAD_DEPLOY_TEST_LOG"
case "$2" in
  upload\ *) cat > "$SANAD_DEPLOY_TEST_UPLOAD" ;;
  upload-client-aliases\ *) cat > "$SANAD_DEPLOY_TEST_ALIAS" ;;
  previous\ *) printf '%040d %064d\n' 2 3 ;;
  hash\ *) printf '%064d\n' 4 ;;
esac
SSH
chmod 0755 "$temporary/ssh"
export PATH="$temporary:$PATH"
export DEPLOY_HOST=example.invalid
export DEPLOY_USER=sanad-deploy-production
export SANAD_DEPLOY_TEST_LOG="$temporary/commands.log"
export SANAD_DEPLOY_TEST_UPLOAD="$temporary/upload.tar.gz"
export SANAD_DEPLOY_TEST_ALIAS="$temporary/aliases.conf"

identity=1111111111111111111111111111111111111111
mkdir "$temporary/updates"
printf '<rss/>\n' > "$temporary/updates/appcast.xml"
printf '{}\n' > "$temporary/updates/release-manifest.json"
digest="$($SCRIPT_DIR/deploy_production_asset.sh publish static-updates "$identity" "$temporary/updates")"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]]
test "$($SCRIPT_DIR/deploy_production_asset.sh publish static-updates "$identity" "$temporary/updates")" = "$digest"
archived="$(tar -tzf "$temporary/upload.tar.gz" | sort | tr '\n' ' ' | sed 's/ $//')"
test "$archived" = 'appcast.xml release-manifest.json'
grep -Eq '^upload static-updates [0-9a-f]{40} [0-9a-f]{64} [1-9][0-9]*$' "$temporary/commands.log"
grep -Eq '^install static-updates [0-9a-f]{40} [0-9a-f]{64}$' "$temporary/commands.log"

read -r previous_identity previous_digest \
  <<<"$($SCRIPT_DIR/deploy_production_asset.sh previous static-updates)"
test "$previous_identity" = 0000000000000000000000000000000000000002
test "$previous_digest" = 0000000000000000000000000000000000000000000000000000000000000003
test "$($SCRIPT_DIR/deploy_production_asset.sh hash static-updates appcast.xml)" = \
  0000000000000000000000000000000000000000000000000000000000000004

manifest_digest="$(printf manifest | sha256sum | awk '{print $1}')"
printf '# release-manifest.json sha256: %s\n' "$manifest_digest" > "$temporary/source-aliases.conf"
$SCRIPT_DIR/deploy_production_asset.sh deploy-client-aliases \
  v9.8.7 "$manifest_digest" "$temporary/source-aliases.conf" >/dev/null
cmp -s "$temporary/source-aliases.conf" "$temporary/aliases.conf"
grep -Eq '^upload-client-aliases v9\.8\.7 [0-9a-f]{64} [0-9a-f]{64} [1-9][0-9]*$' "$temporary/commands.log"
grep -Eq '^deploy-client-aliases v9\.8\.7 [0-9a-f]{64} [0-9a-f]{64}$' "$temporary/commands.log"

if $SCRIPT_DIR/deploy_production_asset.sh hash static-updates install.sh >/dev/null 2>&1; then
  echo "Unexpected static hash target passed the client allowlist." >&2
  exit 1
fi

echo "production-deployment-client=pass"
