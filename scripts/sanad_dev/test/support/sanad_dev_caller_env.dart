import 'dart:io';

import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;

/// Resolves the runtime in the exact way sanad-dev lifecycle handlers do.
///
/// Lifecycle commands resolve their runtime through `_callerDirectory`, which
/// honors an inherited `SANAD_DEV_CALLER_DIR` before falling back to the
/// process working directory. Integration tests that write a stale launcher
/// record on disk must resolve the runtime with this same formula so the Home
/// and agent port the record key uses matches what the handler will read,
/// regardless of whether a live sanad-dev shell exported an ambient
/// `SANAD_DEV_CALLER_DIR`.
Future<runtime_context.SanadDevRuntime> resolveHandlerRuntime({
  String? sanadHomeOverride,
}) async {
  final caller =
      Platform.environment['SANAD_DEV_CALLER_DIR'] ?? Directory.current.path;
  return runtime_context.discoverSanadDevRuntime(
    callerDirectory: caller,
    sanadHomeOverride: sanadHomeOverride,
  );
}
