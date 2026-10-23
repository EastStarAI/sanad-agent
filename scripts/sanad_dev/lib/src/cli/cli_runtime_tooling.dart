part of '../../sanad_dev_cli.dart';

/// Dispatches the runtime tooling commands that extend the original lifecycle
/// set: `reset`, `apply`, `refresh`, and the cached compiled-CLI runner `cli`.
///
/// Returns false when [parsed] is not one of them, so the caller can continue
/// with the established command dispatch.
Future<bool> dispatchSanadDevRuntimeToolingCommand(
  SanadDevCliInvocation parsed,
  List<String> args, {
  String? sanadHomePath,
}) async {
  switch (parsed.command) {
    case 'reset':
      await handleRuntimeReset(
        fixture: parsed.fixtureName,
        saveFixture: parsed.saveFixtureName,
        includeMcpConfig: parsed.includeMcpConfig,
        keepData: parsed.keepData,
        // `reset` exists for testable runtimes, so the driver entry point is
        // always part of its launch contract.
        driverMode: true,
        dryRun: parsed.dryRun,
        device: parsed.device,
        clientInstanceSlot: parsed.clientInstanceSlot,
        sanadHomePath: sanadHomePath,
      );
      return true;
    case 'apply':
      await handleRuntimeApply(
        dryRun: parsed.dryRun,
        driverMode: parsed.driverMode,
        force: parsed.forceRestart,
        sanadHomePath: sanadHomePath,
      );
      return true;
    case 'refresh':
      final at = parsed.refreshAt;
      if (at == null || at.trim().isEmpty) {
        stderr.writeln(
          'refresh requires --at <+duration>, for example --at +2m.',
        );
        exitCode = 64;
        return true;
      }
      await handleRuntimeRefresh(at: at, sanadHomePath: sanadHomePath);
      return true;
    case 'cli':
      await handleCompiledCliCommand(
        args.length > 1 ? args.sublist(1) : const [],
        sanadHomePath: sanadHomePath,
      );
      return true;
    default:
      return false;
  }
}
