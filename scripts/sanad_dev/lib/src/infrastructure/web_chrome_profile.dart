import 'dart:io';

import 'client_launch_profile.dart';
import 'secure_runtime_file.dart';

/// Home-relative directory that owns persistent Chrome profiles for Web Clients.
const sanadDevWebProfileDirectoryName = 'chrome-web';

/// flutter_tools option that forwards one extra flag to the browser it starts.
const sanadDevWebBrowserFlagArgument = '--web-browser-flag=';

/// Browser flag that selects the profile directory Chrome must use.
const sanadDevWebUserDataDirFlag = '--user-data-dir=';

/// Profile directory name used when no Client instance slot was requested.
const sanadDevWebPrimaryProfileName = 'primary';

/// Absolute profile directory for one Web Client of [sanadHome].
///
/// The profile is Home-scoped runtime state: it lives under `dev/` beside the
/// launcher lease, so one Home can never read another Home's browser session and
/// Home fixtures never capture it. Web storage is keyed by the browser profile
/// plus the origin, and flutter_tools otherwise picks a fresh temporary profile
/// for every `-d chrome` launch.
String sanadDevWebChromeProfileDirectory(
  String sanadHome, {
  String? clientInstanceSlot,
  String? separator,
}) {
  final trimmedHome = sanadHome.trim();
  if (trimmedHome.isEmpty) {
    throw const FormatException(
      'Client Web profile requires a Sanad Home directory.',
    );
  }
  final slot = clientInstanceSlot?.trim() ?? '';
  if (slot.isNotEmpty && !isValidSanadDevClientInstanceSlot(slot)) {
    throw const FormatException(
      'Client instance must use 1-32 lowercase letters, digits, or hyphens.',
    );
  }
  final resolvedSeparator = separator ?? Platform.pathSeparator;
  final root = trimmedHome.replaceAll(RegExp(r'[\\/]+$'), '');
  return [
    root,
    'dev',
    sanadDevWebProfileDirectoryName,
    slot.isEmpty ? sanadDevWebPrimaryProfileName : slot,
  ].join(resolvedSeparator);
}

/// Points a Chrome Client at a persistent, Home-scoped browser profile.
///
/// `flutter run -d chrome` creates a temporary profile per launch unless the
/// caller supplies `--user-data-dir`, and the Web Client keeps its tokens and
/// device identity only in `localStorage`, which is scoped to that profile.
/// Supplying the directory is therefore what lets a restarted Web Client resume
/// the session it already had instead of signing in again.
///
/// An inherited flag is always removed first, so applying this twice (the
/// launcher reapplies it for an additional Chrome Client) replaces the previous
/// profile instead of duplicating the argument.
Future<void> applySanadDevWebBrowserProfile(
  List<String> arguments, {
  required String device,
  required String sanadHome,
  String? clientInstanceSlot,
}) async {
  arguments.removeWhere(
    (argument) =>
        argument.startsWith(sanadDevWebBrowserFlagArgument) &&
        argument
            .substring(sanadDevWebBrowserFlagArgument.length)
            .startsWith(sanadDevWebUserDataDirFlag),
  );
  if (device != 'chrome') return;

  final directory = sanadDevWebChromeProfileDirectory(
    sanadHome,
    clientInstanceSlot: clientInstanceSlot,
  );
  // flutter_tools declares --web-browser-flag without splitCommas: false, so a
  // comma in the value would silently become two browser flags.
  if (directory.contains(',')) {
    throw FormatException(
      'A Sanad Home path cannot contain a comma because flutter_tools splits '
      'browser flags on commas: $directory',
    );
  }
  await secureRuntimeDirectory(sanadHome, directory);
  arguments.add(
    '$sanadDevWebBrowserFlagArgument$sanadDevWebUserDataDirFlag$directory',
  );
}
