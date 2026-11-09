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

/// Owns the one notice that explains a pending operating-system authorization
/// dialog.
///
/// The notice is printed only by a process that may show the dialog
/// ([SecretVaultPolicy.interactionAllowed]) and only once per process. A
/// process that forbids interaction never prints it, because no dialog can
/// appear and its read returns immediately with a reason-coded failure; a
/// background query therefore never announces a wait that is not happening.
///
/// The sink is injectable, so a test asserts presence and absence without a
/// real operating-system vault and without a terminal.
abstract final class SecretVaultNotice {
  /// The sink the notice is written to; `stderr` until a caller replaces it.
  static StringSink? sink = stderr;
  static bool _printed = false;

  /// Whether this process already announced a pending authorization.
  static bool get printed => _printed;

  /// Prints the notice once, and only when this process may start the dialog.
  ///
  /// Returns whether it printed, so a caller can assert the decision instead of
  /// observing a side effect.
  static bool announcePendingAuthorization({
    String item = agentVaultKeychainService,
  }) {
    if (_printed) return false;
    if (!SecretVaultPolicy.interactionAllowed) return false;
    _printed = true;
    try {
      sink?.writeln(keychainApprovalWaitNotice(item));
    } on Object {
      // A detached or closed sink must not fail the vault query; the
      // authorization dialog itself explains the wait.
    }
    return true;
  }

  /// Restores the process default; a Dart test uses it between cases.
  static void reset() {
    _printed = false;
    sink = stderr;
  }
}

/// How far this process may go to unlock the operating-system credential vault.
///
/// The Agent vault is the macOS Keychain, Windows DPAPI or Linux Secret
/// Service. Reading an item whose access control does not accept the calling
/// binary makes macOS raise an authorization dialog; the reading thread blocks
/// inside the security framework until somebody answers it. Only an explicit
/// interactive grant (`sanad vault authorize`) and an interactive CLI command
/// have such a person. A daemon, a command driven by the Client, a scheduler, a
/// delegate relay or a closed pipe does not, so it must never start that
/// dialog: it either succeeds without the vault or fails closed with a
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

  /// A daemon entry point: the process runs behind the desktop app, a service
  /// manager, or a pipe, so no person is guaranteed to be in front of it.
  daemonBackground,

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
      SecretVaultInteractionEvidence.daemonBackground => 'daemon_background',
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
  /// A daemon never starts an operating-system authorization dialog. It runs
  /// behind the desktop app, a service manager, or a pipe, so nobody is
  /// guaranteed to be in front of it, and a dialog it cannot show blocks the
  /// reading thread before the listener, the banner, or `/health` exists.
  /// Access is granted only by an explicit user action (`sanad vault authorize`,
  /// the one interactive grant path), so a daemon whose vault stays closed
  /// reports it through one state line and `/health` instead of prompting.
  static const daemonEntryDecision = SecretVaultInteractionDecision(
    SecretVaultInteraction.forbidden,
    SecretVaultInteractionEvidence.daemonBackground,
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

  /// True when this process classified its command as secret-free and has not
  /// opened the vault since. Writing a provider secret in such a process would
  /// fall back to a plaintext file, so it fails closed instead.
  ///
  /// The state is true only while no vault is open: opening one clears it
  /// through [markVaultOpened], because the runtime that opened the vault does
  /// have credential access even when the entry point did not open it.
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

  /// Records that this process opened the Agent vault, so it is no longer a
  /// [vaultSkipped] process.
  ///
  /// [apply] classifies a command line *before* dispatch. One command family,
  /// `run`, deliberately defers the open to the runtime it selects, and the
  /// in-process runtime then opens the vault it needs. A process that really
  /// opened the vault has real credential access, so a secure-store write must
  /// not be refused by a decision that was taken before that open.
  ///
  /// `SecretVaults` calls this on every open, so the invariant is
  /// `vaultSkipped == true` only while this process has no open vault.
  static void markVaultOpened() {
    _vaultSkipped = false;
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
