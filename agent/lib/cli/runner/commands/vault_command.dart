import 'dart:async';

import '../../../core/auth/secret_vault.dart';
import '../../../core/constants.dart';
import '../sanad_command.dart';

/// The one explicit action a person takes to grant the Agent access to the
/// operating-system credential store.
///
/// A daemon never starts an authorization dialog (see
/// `SecretVaultPolicy.daemonEntryDecision`), so an item whose access control does
/// not accept the running binary stays unreadable until somebody asks for the
/// dialog here, in a terminal, where it can be shown and answered.
class VaultCommand extends SanadCommand {
  VaultCommand({super.customAction}) {
    addSubcommand(
      VaultAuthorizeCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
  }

  @override
  String get name => 'vault';

  @override
  String get description =>
      'Inspect and grant the Agent access to its operating-system credential '
      'vault';

  @override
  String get invocation => 'sanad vault <authorize> [options]';

  @override
  Future<int> execute() async {
    // No default action: the only subcommand starts an operating-system
    // dialog, so a bare `sanad vault` prints usage instead of asking.
    printUsage();
    return 0;
  }
}

/// Opens the Agent vault in a process that is allowed to show the dialog.
///
/// This is the explicit interactive grant. It is terminal-only, it prints the
/// existing pending-authorization notice before its first read, it never prints
/// a secret value, and a failure leaves the vault exactly as closed as it was.
class VaultAuthorizeCommand extends SanadCommand {
  VaultAuthorizeCommand({super.customAction}) {
    addCommonOptions(argParser);
  }

  @override
  String get name => 'authorize';

  @override
  String get description =>
      'Ask the operating system to authorize this Agent for its credential '
      'vault';

  @override
  Future<int> execute() async {
    if (!SecretVaultPolicy.interactionAllowed) {
      stderrSink.writeln(
        'sanad vault authorize needs a terminal: it is the only command that '
        'may show an operating-system authorization dialog, and this process '
        'cannot (${SecretVaultPolicy.interactionCode}). Run it from a terminal '
        'without --json or --quiet.',
      );
      return 1;
    }

    final home = getSanadHome();
    stdoutSink.writeln(
      'Opening the Agent vault for $home. If the operating system asks whether '
      'this Agent may read its own items, approve it once.',
    );

    // The store prints the pending-authorization notice itself, before its
    // first read, and only because this process may show the dialog.
    final vaults = await SecretVaults.open();
    if (vaults.available) {
      stdoutSink.writeln(
        'Agent vault is available: provider keys, MCP secrets, user secrets '
        'and the Device Credential are readable in this session.',
      );
      return 0;
    }

    // The vault stays closed, and the message says what is unreadable, why,
    // and what to do next. It carries no secret value.
    stderrSink.writeln(vaults.unavailableStateMessage);
    return 1;
  }
}
