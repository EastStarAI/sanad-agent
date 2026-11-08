part of '../../sanad_dev_cli.dart';

/// Dispatches the commands that project or prune the multi-worktree dev area.
///
/// Both commands are worktree-agnostic: they read every worktree and the primary
/// Home, so they run before the caller's workspace Home is inferred and never
/// pay for that inference. Returns false for every other command.
Future<bool> dispatchSanadDevDevAreaCommand(
  SanadDevCliInvocation parsed,
  List<String> args,
) async {
  if (parsed.command == 'inventory') {
    if (parsed.confirm) {
      stderr.writeln('--confirm does not apply to inventory.');
      exitCode = 64;
      return true;
    }
    await handleSanadDevInventory(
      showAll: parsed.showAll,
      json: parsed.jsonOutput,
      pullRequests: parsed.pullRequestLookup,
    );
    return true;
  }

  if (parsed.command != 'cleanup-orphans') return false;

  // The dev area is derived from the primary Home, not from one worktree, so an
  // explicit Home selector would only be ignored.
  if (parsed.sanadHomePath != null) {
    stderr.writeln(
      '--home does not apply to cleanup-orphans; it targets the primary dev area.',
    );
    exitCode = 64;
    return true;
  }
  if (args.any((argument) => argument == '--dry-run') && parsed.confirm) {
    stderr.writeln('--dry-run cannot be combined with --confirm.');
    exitCode = 64;
    return true;
  }
  if (parsed.pullRequestLookup) {
    stderr.writeln('--pr does not apply to cleanup-orphans.');
    exitCode = 64;
    return true;
  }
  await handleSanadDevOrphanCleanup(
    confirm: parsed.confirm,
    json: parsed.jsonOutput,
  );
  return true;
}
