# Sanad Client Release Tooling

This directory contains platform build scripts and update-feed tooling for
Sanad Client.

## Release assets

The release pipeline publishes the supported client packages, including:

- `sanad-client-<version>-macos-universal.dmg`
- `sanad-client-<version>-windows-x64.exe`
- `sanad-client-<version>-linux-x64.tar.gz`
- `sanad-client-<version>-android-universal.apk`

Store or hosted-web destinations are linked from the GitHub Release when they
apply.

## Platform tooling

- `macos/` builds the macOS DMG and owns the macOS release helper.
- `windows/` builds and verifies the Windows x64 installer. Its automated
  installer path uses NSIS.
- `ios/` owns the Internal TestFlight export policy.
- `release/release-contract.json` and `release/contract/` at repository
  root own version validation, manifest parsing, Appcast generation, and
  checksum verification shared with the agent.

Android, iOS, Linux, and web artifacts are built by their owning release
workflow even when they do not need a dedicated script in this directory.
Adding a platform script does not by itself make that target supported; its
artifact must also pass the verification contract below.

## Update feed

The Appcast generator runs only after immutable signed assets exist. The final
generated feed is not tracked as source; CI publishes it atomically to:

```text
https://updates.sanad.eaststarai.com/appcast.xml
```

Deployment keeps a rollback copy. Public verification keys may be tracked, but
private signing keys, certificates, notarization credentials, and deployment
credentials belong only in protected CI environments.

## Verification

Every supported package must pass build, signature, clean install, update,
rollback, and uninstall checks. Fork pull requests never receive release or
deployment secrets.

Verification must also confirm that:

- the package name and architecture match the release manifest and user guide;
- the installed application reports the release version;
- required runtime libraries and assets are included;
- update metadata references an already published immutable asset;
- user data survives install, update, and uninstall according to the documented
  lifecycle;
- rollback restores a launchable signed build.

Production feed publication uses a protected environment, least-privilege
credentials, atomic replacement, and a retained rollback copy.
