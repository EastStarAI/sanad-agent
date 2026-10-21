/// Typed pre-dispatch rejection raised when canonical history has no truthful
/// wire representation for the destination route (Task 116 D4).
///
/// Raised by an adapter's request builder before any HTTP call. It carries
/// bounded diagnostics only: the destination route, a closed reason code and
/// an affected-message count. It never carries message content, reasoning,
/// provider payloads or credentials. The runner presents it as a blocked,
/// locally decided invalid request without failover, retry, thinking change
/// or history change.
final class ProviderHistoryProjectionException implements Exception {
  /// Foreign or unrecorded tool-call history sits where the destination route
  /// requires a reasoning echo it cannot be given truthfully.
  static const foreignToolTurnRequiresReasoning =
      'foreign_tool_turn_requires_reasoning';

  /// A same-route tool-call turn's recorded reasoning shape is one the route
  /// does not accept on replay.
  static const sameRouteReasoningUnrecoverable =
      'same_route_reasoning_unrecoverable';

  /// A tool call has no paired tool result, so the destination protocol
  /// cannot represent it without dropping it.
  static const unpairedToolCall = 'unpaired_tool_call';

  static const reasonCodes = {
    foreignToolTurnRequiresReasoning,
    sameRouteReasoningUnrecoverable,
    unpairedToolCall,
  };

  /// Destination route as `<provider instance>/<model>`.
  final String route;
  final String reasonCode;
  final int affectedCount;

  ProviderHistoryProjectionException({
    required this.route,
    required this.reasonCode,
    required this.affectedCount,
  }) {
    if (!reasonCodes.contains(reasonCode)) {
      throw ArgumentError.value(reasonCode, 'reasonCode');
    }
  }

  /// Bounded, actionable notice text. It deliberately does not suggest
  /// compaction: the summarizer replays the same history on the same route.
  String userMessage({required String providerDisplayName, String? modelId}) {
    final target = modelId == null || modelId.isEmpty
        ? providerDisplayName
        : '$modelId on $providerDisplayName';
    final steps = affectedCount == 1 ? '1 step' : '$affectedCount steps';
    return switch (reasonCode) {
      unpairedToolCall =>
        'This conversation has a tool call without a result ($steps), '
            'which $target cannot accept. Nothing was sent. Continue on the '
            'previous model, or start a new conversation.',
      sameRouteReasoningUnrecoverable =>
        'This conversation has tool steps whose reasoning $target cannot '
            'accept back ($steps). Nothing was sent. Turn thinking off for '
            'this model, continue on another model, or start a new '
            'conversation.',
      _ =>
        'This conversation has tool steps from another model that $target '
            'cannot accept with thinking on ($steps). Nothing was sent. '
            'Continue on the previous model, or start a new conversation.',
    };
  }

  @override
  String toString() =>
      'ProviderHistoryProjectionException(route: $route, '
      'reason: $reasonCode, count: $affectedCount)';
}
