enum TurnReplayAction { retry, edit }

enum TurnReplaySafety { safe, unsafe, unknown }

class TurnReplayResult {
  final String outcome;
  final TurnReplaySafety safety;
  final bool requiresConfirmation;
  final bool requiresSteerDropConfirmation;
  final bool containsSteers;
  final int? historyRevision;

  const TurnReplayResult({
    required this.outcome,
    required this.safety,
    required this.requiresConfirmation,
    this.requiresSteerDropConfirmation = false,
    this.containsSteers = false,
    this.historyRevision,
  });

  bool get isAccepted => outcome == 'accepted';

  factory TurnReplayResult.fromJson(Map<String, dynamic> json) {
    final safetyName = json['replay_safety']?.toString();
    final revision = json['history_revision'];
    final outcome = json['outcome']?.toString() ?? 'invalid_response';
    return TurnReplayResult(
      outcome: outcome,
      safety: TurnReplaySafety.values.firstWhere(
        (value) => value.name == safetyName,
        orElse: () => TurnReplaySafety.unknown,
      ),
      requiresConfirmation: json['requires_confirmation'] == true,
      requiresSteerDropConfirmation:
          json['requires_steer_drop_confirmation'] == true ||
          outcome == 'steer_reinjection_confirmation_required',
      containsSteers: json['contains_steers'] == true,
      historyRevision: revision is num ? revision.toInt() : int.tryParse(revision?.toString() ?? ''),
    );
  }
}
