import 'dart:io';

import 'agent_secret_store_contract.dart';

/// The macOS Keychain service name shared by every Agent vault item.
///
/// It is the item label an authorization dialog shows, so a diagnostic may name
/// it; it carries no secret, and it is not a key or an account.
const agentVaultKeychainService = 'ai.eaststar.sanad.agent';

/// The one stderr line an interactive process prints before its first Keychain
/// read.
///
/// It exists so an operator knows why a command stopped, and it names an item
/// label only, never a secret value. A process with nobody present never prints
/// it, because it never starts the dialog.
String keychainApprovalWaitNotice([String item = agentVaultKeychainService]) =>
    'Waiting for macOS Keychain approval for $item…';

/// How far this process may go to unlock the operating-system credential vault.
///
/// The Agent vault is the macOS Keychain, Windows DPAPI or Linux Secret
/// Service. Reading an item whose access control does not accept the calling
/// binary makes macOS raise an authorization dialog; the reading thread blocks
/// inside the security framework until somebody answers it. A daemon or an
/// interactive command has such a person. A command driven by the Client, a
/// scheduler, a delegate relay or a closed pipe does not, so it must never start
/// that dialog: it either succeeds without the vault or fails closed with a
/// diagnostic.
enum SecretVaultInteraction {
  /// A person can answer an OS authorization dialog for this process.
  allowed,

  /// No person is present; the process must never start an OS prompt.
  forbidden,
}

/// Detection evidence for the "no human present" decision.
///
/// Every value names the concrete observation that produced it, so a diagnostic
/// can explain *why* a process will not prompt. Detection never guesses from
/// heuristics such as a parent command name.
enum SecretVaultInteractionEvidence {
  /// No machine-output flag, no closed pipe, no supervisor: a terminal with a
  /// person in front of it.
  interactiveTerminal,

  /// `--json`, `--quiet` or `-q`: output belongs to a machine consumer.
  machineOutputFlag,

  /// `--child-process`: the supervised child of a daemon parent, whose stdio is
  /// inherited from a launchd/app-owned parent with no prompt owner.
  supervisedChild,

  /// The daemon itself, which keeps the normal prompt: it is a long-lived
  /// process an operator starts, and its one-time authorization dialog is the
  /// intended way to grant access to the vault it migrates.
  daemonEntryPoint,

  /// `SANAD_SECRET_VAULT_INTERACTION=forbid`: the spawner declared it.
  declaredByEnvironment,

  /// `SANAD_SECRET_VAULT_INTERACTION=allow`: the spawner declared it.
  declaredInteractiveByEnvironment,

  /// stdin or stdout is not a terminal, so the process is driven by the Client,
  /// a scheduler, a delegate relay, a script, or a pipe.
  noTerminal,
}

/// Stable, non-secret reason code for one detection evidence.
String secretVaultEvidenceCode(SecretVaultInteractionEvidence evidence) =>
    switch (evidence) {
      SecretVaultInteractionEvidence.interactiveTerminal =>
        'interactive_terminal',
      SecretVaultInteractionEvidence.machineOutputFlag => 'machine_output',
      SecretVaultInteractionEvidence.supervisedChild => 'supervised_child',
      SecretVaultInteractionEvidence.daemonEntryPoint => 'daemon_entry_point',
      SecretVaultInteractionEvidence.declaredByEnvironment =>
        'declared_non_interactive',
      SecretVaultInteractionEvidence.declaredInteractiveByEnvironment =>
        'declared_interactive',
      SecretVaultInteractionEvidence.noTerminal => 'no_terminal',
    };

/// The outcome of [detectSecretVaultInteraction].
final class SecretVaultInteractionDecision {
  const SecretVaultInteractionDecision(this.interaction, this.evidence);

  final SecretVaultInteraction interaction;
  final SecretVaultInteractionEvidence evidence;

  bool get allowsPrompt => interaction == SecretVaultInteraction.allowed;

  /// Stable, non-secret reason code for diagnostics and `/health`.
  String get code => secretVaultEvidenceCode(evidence);

  @override
  String toString() => 'SecretVaultInteraction.${interaction.name} ($code)';
}

/// Process-scoped vault policy, set once by an entry point before the vault is
/// opened.
///
/// Two independent facts live here:
/// * [interaction] — may this process start an OS authorization dialog?
/// * [vaultSkipped] — did this process deliberately decide not to open the
///   vault, so that no secret may be written to a plaintext fallback?
abstract final class SecretVaultPolicy {
  static const interactionEnvironmentVariable =
      'SANAD_SECRET_VAULT_INTERACTION';

  /// The decision the daemon applies at every entry point.
  ///
  /// The daemon is not a machine-driven probe: an operator starts it (from the
  /// desktop app, a launchd service, or a terminal), its one-time authorization
  /// dialog is the intended UX for the vault it migrates, and a closed vault is
  /// reported through its log and `/health`. It therefore keeps the prompt and
  /// does not inherit the CLI's stdio-shaped detection.
  static const daemonEntryDecision = SecretVaultInteractionDecision(
    SecretVaultInteraction.allowed,
    SecretVaultInteractionEvidence.daemonEntryPoint,
  );

  static SecretVaultInteraction _interaction = SecretVaultInteraction.allowed;
  static SecretVaultInteractionEvidence _evidence =
      SecretVaultInteractionEvidence.interactiveTerminal;
  static bool _vaultSkipped = false;

  static SecretVaultInteraction get interaction => _interaction;

  static bool get interactionAllowed =>
      _interaction == SecretVaultInteraction.allowed;

  static SecretVaultInteractionEvidence get evidence => _evidence;

  /// Why this process will not prompt, or `interactive_terminal` when it will.
  static String get interactionCode => secretVaultEvidenceCode(_evidence);

  /// True when this process classified its command as secret-free and therefore
  /// never opened the vault. Writing a provider secret in such a process would
  /// fall back to a plaintext file, so it fails closed instead.
  static bool get vaultSkipped => _vaultSkipped;

  /// Refuses a plaintext secret mutation in a [vaultSkipped] process.
  ///
  /// A vault-free command was classified as one that cannot read or write an
  /// Agent secret. If it nevertheless reaches a provider-secret write, the only
  /// backend available to it is a plaintext file, which would silently bypass
  /// the Agent vault and leave a secret on disk. It therefore fails closed with
  /// a diagnostic instead of degrading to plaintext.
  static void rejectPlaintextSecretMutation(String operation) {
    if (!_vaultSkipped) return;
    throw AgentSecretStoreUnavailable(
      'This command never opened the Agent vault because it was classified as '
      'secret-free, so it cannot $operation a provider secret; run the command '
      'that owns that secret (for example `sanad providers`) instead.',
      reasonCode: AgentSecretStoreUnavailableReason.plaintextFallbackBlocked,
    );
  }

  /// Applies [decision] and records whether the caller skipped the vault.
  static void apply(
    SecretVaultInteractionDecision decision, {
    required bool vaultSkipped,
  }) {
    _interaction = decision.interaction;
    _evidence = decision.evidence;
    _vaultSkipped = vaultSkipped;
  }

  /// Restores the process default; a Dart test uses it between cases.
  static void reset() {
    _interaction = SecretVaultInteraction.allowed;
    _evidence = SecretVaultInteractionEvidence.interactiveTerminal;
    _vaultSkipped = false;
  }
}

/// Decides whether an OS authorization dialog may be shown for this process.
///
/// The inputs are explicit and testable: the command line, the spawner's
/// declaration, and whether stdin/stdout are terminals. There is no heuristics
/// step, so the answer for a given command line and stdio shape is fixed and a
/// test can assert it.
SecretVaultInteractionDecision detectSecretVaultInteraction(
  List<String> arguments, {
  Map<String, String>? environment,
  bool? stdinIsTerminal,
  bool? stdoutIsTerminal,
}) {
  final source = environment ?? Platform.environment;
  final declared = source[SecretVaultPolicy.interactionEnvironmentVariable]
      ?.trim()
      .toLowerCase();
  if (declared == 'forbid' || declared == 'false' || declared == 'never') {
    return const SecretVaultInteractionDecision(
      SecretVaultInteraction.forbidden,
      SecretVaultInteractionEvidence.declaredByEnvironment,
    );
  }
  if (declared == 'allow' || declared == 'true' || declared == 'always') {
    return const SecretVaultInteractionDecision(
      SecretVaultInteraction.allowed,
      SecretVaultInteractionEvidence.declaredInteractiveByEnvironment,
    );
  }
  if (arguments.contains('--json') ||
      arguments.contains('--quiet') ||
      arguments.contains('-q')) {
    return const SecretVaultInteractionDecision(
      SecretVaultInteraction.forbidden,
      SecretVaultInteractionEvidence.machineOutputFlag,
    );
  }
  if (arguments.contains('--child-process')) {
    return const SecretVaultInteractionDecision(
      SecretVaultInteraction.forbidden,
      SecretVaultInteractionEvidence.supervisedChild,
    );
  }
  final stdinTerminal =
      stdinIsTerminal ?? _hasTerminal(() => stdin.hasTerminal);
  final stdoutTerminal =
      stdoutIsTerminal ?? _hasTerminal(() => stdout.hasTerminal);
  if (!stdinTerminal || !stdoutTerminal) {
    return const SecretVaultInteractionDecision(
      SecretVaultInteraction.forbidden,
      SecretVaultInteractionEvidence.noTerminal,
    );
  }
  return const SecretVaultInteractionDecision(
    SecretVaultInteraction.allowed,
    SecretVaultInteractionEvidence.interactiveTerminal,
  );
}

bool _hasTerminal(bool Function() probe) {
  try {
    return probe();
  } on Object {
    // A detached or already closed stdio cannot host a prompt.
    return false;
  }
}
