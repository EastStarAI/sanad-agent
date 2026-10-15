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
/// constant drifts from `client/pubspec.yaml`.
const String sanadClientCliVersion = '1.0.15';
