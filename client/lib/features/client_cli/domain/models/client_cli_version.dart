/// Single source of truth for the `sanad-client` relay tool version.
///
/// The standalone `sanad-client` entry runs on the plain Dart VM without the
/// Flutter engine, so it cannot read `PackageInfo` like the desktop Client
/// does. The running Client reports its own runtime version through the CLI
/// host record and `/health`, and the CLI compares major versions only, so this
/// value must mirror the `client/pubspec.yaml` release version without
/// duplicating that literal anywhere else.
///
/// `client/test/unit/client_cli/client_cli_version_test.dart` fails when this
/// constant drifts from `client/pubspec.yaml`. Release preparation
/// (`agent/tool/release_tool.dart prepare-release`) advances this literal with
/// the Client release version, and `check-preparation` rejects a stale value,
/// so the literal is never edited by hand.
const String sanadClientCliVersion = '1.0.18';
