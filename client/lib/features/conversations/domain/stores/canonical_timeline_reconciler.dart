import '../models/canonical_event.dart';

/// Reconciles canonical timeline rows by their type-appropriate authoritative
/// identities while preserving causal order supplied by history pages.
class CanonicalTimelineReconciler {
  const CanonicalTimelineReconciler._();

  static bool matches(
    CanonicalEvent left,
    CanonicalEvent right, {
    bool allowLegacyUserFallback = false,
  }) {
    if (left.sessionId != null && right.sessionId != null && left.sessionId != right.sessionId) {
      return false;
    }
    if (left.kind != right.kind) return false;
    if (left.id.isNotEmpty && left.id == right.id) return true;

    final leftMessageId = left.messageId;
    final rightMessageId = right.messageId;
    if (left.kind == EventKind.toolCall && right.kind == EventKind.toolCall) {
      final leftToolCallId = left.toolCallId;
      final rightToolCallId = right.toolCallId;
      if (leftToolCallId != null && rightToolCallId != null) {
        return leftToolCallId == rightToolCallId;
      }
      return leftMessageId != null && rightMessageId != null && leftMessageId == rightMessageId;
    }
    if (leftMessageId != null && rightMessageId != null) {
      return leftMessageId == rightMessageId;
    }

    if (left.kind == EventKind.userMessage && right.kind == EventKind.userMessage) {
      final leftRequestId = left.requestId;
      final rightRequestId = right.requestId;
      if (leftRequestId != null && rightRequestId != null) {
        return leftRequestId == rightRequestId;
      }
      if (allowLegacyUserFallback &&
          (leftMessageId == null || rightMessageId == null) &&
          (leftRequestId == null || rightRequestId == null) &&
          left.text == right.text) {
        return left.timestamp.difference(right.timestamp).abs() <= const Duration(seconds: 1);
      }
      return false;
    }

    if (left.kind == right.kind) {
      final leftModelStepId = left.modelStepId;
      final rightModelStepId = right.modelStepId;
      if (leftModelStepId != null && rightModelStepId != null) {
        return leftModelStepId == rightModelStepId;
      }
      final leftRunId = left.runId;
      final rightRunId = right.runId;
      if (leftRunId != null && rightRunId != null) {
        return leftRunId == rightRunId;
      }
    }
    return false;
  }

  static List<CanonicalEvent> fold(
    Iterable<CanonicalEvent> events, {
    bool allowLegacyUserFallback = false,
  }) {
    final folded = <CanonicalEvent>[];
    for (final event in events) {
      final index = folded.indexWhere(
        (existing) => matches(
          existing,
          event,
          allowLegacyUserFallback: allowLegacyUserFallback,
        ),
      );
      if (index < 0) {
        folded.add(event);
      } else {
        folded[index] = merge(folded[index], event);
      }
    }
    return folded;
  }

  /// Makes [authoritative] the order authority for its slice while retaining
  /// rows outside that slice around their nearest known causal neighbour.
  static List<CanonicalEvent> mergeAuthoritativeSlice(
    List<CanonicalEvent> retained,
    List<CanonicalEvent> authoritative, {
    bool allowLegacyUserFallback = true,
  }) {
    final foldedAuthoritative = fold(
      authoritative,
      allowLegacyUserFallback: allowLegacyUserFallback,
    );
    if (foldedAuthoritative.isEmpty) return List.of(retained);

    final authoritativeMatchByRetainedIndex = <int, int>{};
    final consumedAuthoritative = <int>{};
    for (var retainedIndex = 0; retainedIndex < retained.length; retainedIndex++) {
      final event = retained[retainedIndex];
      final authoritativeIndex = _firstMatchIndex(
        event,
        foldedAuthoritative,
        consumedAuthoritative,
        allowLegacyUserFallback: allowLegacyUserFallback,
      );

      if (authoritativeIndex >= 0) {
        authoritativeMatchByRetainedIndex[retainedIndex] = authoritativeIndex;
        consumedAuthoritative.add(authoritativeIndex);
        foldedAuthoritative[authoritativeIndex] = merge(
          event,
          foldedAuthoritative[authoritativeIndex],
        );
      }
    }

    if (authoritativeMatchByRetainedIndex.isEmpty) {
      return [...retained, ...foldedAuthoritative];
    }

    final before = <int, List<CanonicalEvent>>{};
    final after = <CanonicalEvent>[];
    for (var retainedIndex = 0; retainedIndex < retained.length; retainedIndex++) {
      if (authoritativeMatchByRetainedIndex.containsKey(retainedIndex)) {
        continue;
      }
      int? nextAuthoritativeIndex;
      for (var next = retainedIndex + 1; next < retained.length; next++) {
        final match = authoritativeMatchByRetainedIndex[next];
        if (match != null) {
          nextAuthoritativeIndex = match;
          break;
        }
      }
      if (nextAuthoritativeIndex == null) {
        after.add(retained[retainedIndex]);
      } else {
        before.putIfAbsent(nextAuthoritativeIndex, () => <CanonicalEvent>[]).add(retained[retainedIndex]);
      }
    }

    return [
      for (var index = 0; index < foldedAuthoritative.length; index++) ...[
        ...?before[index],
        foldedAuthoritative[index],
      ],
      ...after,
    ];
  }

  static int _firstMatchIndex(
    CanonicalEvent retained,
    List<CanonicalEvent> authoritative,
    Set<int> consumed, {
    required bool allowLegacyUserFallback,
  }) {
    for (var index = 0; index < authoritative.length; index++) {
      if (!consumed.contains(index) &&
          matches(
            retained,
            authoritative[index],
            allowLegacyUserFallback: allowLegacyUserFallback,
          )) {
        return index;
      }
    }
    return -1;
  }

  static CanonicalEvent merge(
    CanonicalEvent existing,
    CanonicalEvent incoming,
  ) {
    final merged = existing.merge(incoming);
    return merged.copyWith(
      id: incoming.id,
      kind: incoming.kind,
      timestamp: incoming.timestamp,
      sessionId: incoming.sessionId ?? existing.sessionId,
      runId: incoming.runId ?? existing.runId,
      modelStepId: incoming.modelStepId ?? existing.modelStepId,
      toolCallId: incoming.toolCallId ?? existing.toolCallId,
      eventId: incoming.eventId ?? existing.eventId,
    );
  }
}
