import 'dart:convert';
import 'dart:io';

import 'secure_runtime_file.dart';

const sanadDevStartupAttemptSchemaVersion = 1;

List<String> sanadDevBackgroundChildArguments(
  String scriptPath,
  Iterable<String> originalArguments,
) => [
  scriptPath,
  ...originalArguments.where((argument) => argument != '--background'),
  '--internal-background',
];

enum SanadDevStartupStage {
  preflight,
  recordCreated,
  componentsSpawned,
  readiness,
  managed,
  cleanup,
}

enum SanadDevStartupOutcome { starting, managed, failed }

bool isSanadDevBackgroundPublicationGraceActive(
  DateTime? childExitedAt, {
  DateTime? now,
  Duration grace = const Duration(seconds: 2),
}) {
  if (childExitedAt == null) return false;
  final elapsed = (now ?? DateTime.now()).difference(childExitedAt);
  return !elapsed.isNegative && elapsed < grace;
}

bool isSanadDevStartupAttemptInProgress(
  SanadDevStartupAttempt? attempt, {
  DateTime? now,
  Duration timeout = const Duration(minutes: 6),
}) {
  if (attempt?.outcome != SanadDevStartupOutcome.starting) return false;
  final age = (now ?? DateTime.now().toUtc()).toUtc().difference(
    attempt!.updatedAt,
  );
  return !age.isNegative && age <= timeout;
}

String sanadDevStartupAttemptPath(String sanadHome, int agentPort) =>
    '$sanadHome${Platform.pathSeparator}dev${Platform.pathSeparator}startups'
    '${Platform.pathSeparator}$agentPort.json';

class SanadDevStartupAttempt {
  const SanadDevStartupAttempt({
    required this.attemptId,
    required this.workspaceHash,
    required this.agentPort,
    required this.requestedHome,
    required this.resolvedHome,
    required this.stage,
    required this.outcome,
    required this.updatedAt,
    this.exitStatus,
    this.failureReason,
  });

  factory SanadDevStartupAttempt.fromJson(Map<String, Object?> json) {
    if (json['version'] != sanadDevStartupAttemptSchemaVersion) {
      throw const FormatException('Unsupported startup-attempt version.');
    }
    final attemptId = json['attempt_id'];
    final workspaceHash = json['workspace_hash'];
    final agentPort = json['agent_port'];
    final requestedHome = json['requested_home'];
    final resolvedHome = json['resolved_home'];
    final stage = SanadDevStartupStage.values
        .where((value) => value.name == json['stage'])
        .firstOrNull;
    final outcome = SanadDevStartupOutcome.values
        .where((value) => value.name == json['outcome'])
        .firstOrNull;
    final updatedAt = DateTime.tryParse(json['updated_at'] as String? ?? '');
    if (attemptId is! String ||
        attemptId.isEmpty ||
        workspaceHash is! String ||
        workspaceHash.isEmpty ||
        agentPort is! int ||
        requestedHome is! String ||
        requestedHome.isEmpty ||
        resolvedHome is! String ||
        resolvedHome.isEmpty ||
        stage == null ||
        outcome == null ||
        updatedAt == null) {
      throw const FormatException('Invalid startup-attempt record.');
    }
    return SanadDevStartupAttempt(
      attemptId: attemptId,
      workspaceHash: workspaceHash,
      agentPort: agentPort,
      requestedHome: requestedHome,
      resolvedHome: resolvedHome,
      stage: stage,
      outcome: outcome,
      updatedAt: updatedAt.toUtc(),
      exitStatus: json['exit_status'] as int?,
      failureReason: json['failure_reason'] as String?,
    );
  }

  final String attemptId;
  final String workspaceHash;
  final int agentPort;
  final String requestedHome;
  final String resolvedHome;
  final SanadDevStartupStage stage;
  final SanadDevStartupOutcome outcome;
  final DateTime updatedAt;
  final int? exitStatus;
  final String? failureReason;

  SanadDevStartupAttempt copyWith({
    SanadDevStartupStage? stage,
    SanadDevStartupOutcome? outcome,
    DateTime? updatedAt,
    int? exitStatus,
    String? failureReason,
  }) => SanadDevStartupAttempt(
    attemptId: attemptId,
    workspaceHash: workspaceHash,
    agentPort: agentPort,
    requestedHome: requestedHome,
    resolvedHome: resolvedHome,
    stage: stage ?? this.stage,
    outcome: outcome ?? this.outcome,
    updatedAt: (updatedAt ?? this.updatedAt).toUtc(),
    exitStatus: exitStatus ?? this.exitStatus,
    failureReason: failureReason ?? this.failureReason,
  );

  Map<String, Object?> toJson() => {
    'version': sanadDevStartupAttemptSchemaVersion,
    'attempt_id': attemptId,
    'workspace_hash': workspaceHash,
    'agent_port': agentPort,
    'requested_home': requestedHome,
    'resolved_home': resolvedHome,
    'stage': stage.name,
    'outcome': outcome.name,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    if (exitStatus != null) 'exit_status': exitStatus,
    if (failureReason != null) 'failure_reason': failureReason,
  };
}

Future<void> writeSanadDevStartupAttempt(SanadDevStartupAttempt attempt) =>
    secureRuntimeAtomicWrite(
      attempt.resolvedHome,
      sanadDevStartupAttemptPath(attempt.resolvedHome, attempt.agentPort),
      jsonEncode(attempt.toJson()),
    );

Future<SanadDevStartupAttempt?> readSanadDevStartupAttempt(
  String sanadHome,
  int agentPort,
) async {
  final path = sanadDevStartupAttemptPath(sanadHome, agentPort);
  if (!await File(path).exists()) return null;
  final decoded = jsonDecode(await secureRuntimeReadText(sanadHome, path));
  if (decoded is! Map) {
    throw const FormatException('Invalid startup-attempt record.');
  }
  return SanadDevStartupAttempt.fromJson(decoded.cast<String, Object?>());
}

String sanadDevStartupAttemptLocatorPath(String runtimeDirectory) =>
    '$runtimeDirectory${Platform.pathSeparator}startup-attempt.json';

Future<void> writeSanadDevStartupAttemptLocator({
  required String runtimeDirectory,
  required SanadDevStartupAttempt attempt,
}) => secureRuntimeAtomicWrite(
  runtimeDirectory,
  sanadDevStartupAttemptLocatorPath(runtimeDirectory),
  jsonEncode({
    'version': sanadDevStartupAttemptSchemaVersion,
    'attempt_id': attempt.attemptId,
    'workspace_hash': attempt.workspaceHash,
    'agent_port': attempt.agentPort,
    'resolved_home': attempt.resolvedHome,
  }),
);

Future<SanadDevStartupAttempt?> readLocatedSanadDevStartupAttempt({
  required String runtimeDirectory,
  required String workspaceHash,
}) async {
  final locatorPath = sanadDevStartupAttemptLocatorPath(runtimeDirectory);
  if (!await File(locatorPath).exists()) return null;
  final decoded = jsonDecode(
    await secureRuntimeReadText(runtimeDirectory, locatorPath),
  );
  if (decoded is! Map ||
      decoded['version'] != sanadDevStartupAttemptSchemaVersion ||
      decoded['workspace_hash'] != workspaceHash ||
      decoded['resolved_home'] is! String ||
      decoded['agent_port'] is! int) {
    throw const FormatException('Invalid startup-attempt locator.');
  }
  final attempt = await readSanadDevStartupAttempt(
    decoded['resolved_home']! as String,
    decoded['agent_port']! as int,
  );
  if (attempt == null ||
      attempt.attemptId != decoded['attempt_id'] ||
      attempt.workspaceHash != workspaceHash) {
    throw const FormatException('Stale startup-attempt locator.');
  }
  return attempt;
}
