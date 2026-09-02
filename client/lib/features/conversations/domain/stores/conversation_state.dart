import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';

/// Manages the state of a single conversation session.
///
/// Single source of truth for the UI — accepts `CanonicalEvent`s produced by any
/// agent mapper and merges them with upsert-by-id semantics:
///
/// - `thinking` (running)  → append delta text to the existing bubble.
/// - `thinking` (done)     → replace with the finalized text.
/// - `toolCall`            → merge `tool` fields (input from `tool_use`, output
///                            from `tool_result`) and advance status.
/// - everything else       → replace by id.
class ConversationState {
  ConversationState({ThinkingStreamMode thinkingStreamMode = ThinkingStreamMode.auto})
    : _thinkingStreamMode = thinkingStreamMode;

  final List<CanonicalEvent> _events = [];
  ThinkingStreamMode _thinkingStreamMode;
  final Set<String> _supersededTurnIds = <String>{};
  final Set<String> _supersededMessageIds = <String>{};

  List<CanonicalEvent> get events => List.unmodifiable(_events);

  bool get isEmpty => _events.isEmpty;

  void clear() {
    _events.clear();
    _supersededTurnIds.clear();
    _supersededMessageIds.clear();
  }

  void updateThinkingStreamMode(ThinkingStreamMode value) {
    _thinkingStreamMode = value;
  }

  /// Replace all events with [history]. Used when loading a session from DB.
  ///
  /// `reasoning` events are transient provider-stream artifacts: they are
  /// never persisted into the visible timeline from history, so a session
  /// reopened from the DB never rebuilds them (see transient-reasoning law in
  /// `client/AGENTS.md`).
  void setHistory(List<CanonicalEvent> history) {
    _events.clear();
    for (final event in history) {
      if (event.kind == EventKind.reasoning) continue;
      if (_isSuperseded(event)) continue;
      _applyInternal(event);
    }
  }

  /// Apply a new event to the state.
  void apply(CanonicalEvent event) {
    if (_isSuperseded(event)) return;
    _applyInternal(event);
  }

  void removeThinkingByRunId(String runId) {
    _events.removeWhere(
      (event) => (event.kind == EventKind.thinking || event.kind == EventKind.reasoning) && event.runId == runId,
    );
  }

  void removeRunningThinkingForSession(String sessionId) {
    _events.removeWhere(
      (event) =>
          (event.kind == EventKind.thinking || event.kind == EventKind.reasoning) &&
          event.status == EventStatus.running &&
          event.sessionId == sessionId,
    );
  }

  bool removeRunningThinkingStep({
    required String modelStepId,
    String? runId,
    String? sessionId,
  }) {
    final before = _events.length;
    _events.removeWhere(
      (event) =>
          (event.kind == EventKind.thinking || event.kind == EventKind.reasoning) &&
          event.status == EventStatus.running &&
          event.modelStepId == modelStepId &&
          (runId == null || event.runId == runId) &&
          (sessionId == null || event.sessionId == sessionId),
    );
    return _events.length != before;
  }

  void removeById(String id) {
    _events.removeWhere((event) => event.id == id);
  }

  /// Defensive fallback when `stopped` arrives before a terminal tool_result.
  void cancelRunningToolsForRun({
    required String runId,
    String? sessionId,
    String message = 'Command cancelled by user.',
  }) {
    for (var index = 0; index < _events.length; index++) {
      final event = _events[index];
      if (event.kind != EventKind.toolCall || event.status != EventStatus.running) {
        continue;
      }
      if (event.runId != runId) continue;
      if (sessionId != null && event.sessionId != sessionId) continue;
      _events[index] = event.copyWith(
        status: EventStatus.cancelled,
        tool: {
          ...?event.tool,
          'output': message,
        },
      );
    }
  }

  /// Hide the superseded root turn by stable identity. Late live events with
  /// the same `turn_id` or `message_id` are dropped instead of resurrecting it.
  bool hideSupersededIdentities({
    String? turnId,
    String? messageId,
  }) {
    if (turnId != null && turnId.isNotEmpty) {
      _supersededTurnIds.add(turnId);
    }
    if (messageId != null && messageId.isNotEmpty) {
      _supersededMessageIds.add(messageId);
    }
    final before = _events.length;
    _events.removeWhere(_isSuperseded);
    return _events.length != before;
  }

  bool _isSuperseded(CanonicalEvent event) {
    if (event.metadata?['history_status']?.toString() == 'superseded') {
      return true;
    }
    final turnId = event.turnId;
    final messageId = event.messageId;
    if (turnId != null && _supersededTurnIds.contains(turnId)) return true;
    if (messageId != null && _supersededMessageIds.contains(messageId)) {
      return true;
    }
    return false;
  }

  void _applyInternal(CanonicalEvent event) {
    if (_isRunningAssistantStream(event)) {
      _removeSupersededRunningStream(event);
    }
    // Any event that advances the turn past a running `reasoning` stream
    // supersedes it. Reasoning is a transient, live-only artifact: once a
    // successor event arrives (tool call, thinking text, final answer, or a
    // new user message) the reasoning row is removed rather than finalized,
    // so it never lingers in the timeline or in history.
    if (event.kind != EventKind.reasoning) {
      _dropSupersededRunningReasoning(event);
    }
    if (event.kind == EventKind.toolCall && event.status == EventStatus.running && event.modelStepId != null) {
      _completeThinkingStep(
        modelStepId: event.modelStepId!,
        runId: event.runId,
        sessionId: event.sessionId,
      );
    }
    // Final assistant text supersedes only the ordinary streaming text for the
    // same model step. Provider reasoning is transient: it has already been
    // dropped by the supersede pass above.
    if (event.kind == EventKind.finalAnswer && event.status == EventStatus.done) {
      _events.removeWhere(
        (existing) =>
            existing.kind == EventKind.thinking &&
            existing.status == EventStatus.running &&
            _matchesModelStep(existing, event),
      );
    }

    final index = _events.indexWhere((e) => e.id == event.id);

    if (index == -1) {
      if (event.kind == EventKind.userMessage) {
        final existingIndex = _findMatchingOptimisticUserMessage(event);
        if (existingIndex != -1) {
          _events[existingIndex] = _merge(_events[existingIndex], event);
          return;
        }
      }

      _events.add(event);
      return;
    }

    final existing = _events[index];
    if (event.metadata?['compaction_event'] == true && !_shouldApplyCompactionLifecycle(existing, event)) {
      return;
    }
    _events[index] = _merge(existing, event);
  }

  bool _isRunningAssistantStream(CanonicalEvent event) =>
      (event.kind == EventKind.thinking || event.kind == EventKind.reasoning) && event.status == EventStatus.running;

  /// Remove any still-running `reasoning` rows that the [incoming] event
  /// supersedes. Matching follows the same turn-identity rules as
  /// [_matchesModelStep] (modelStepId when present, else runId), and falls
  /// back to sessionId so a bare successor still clears the live reasoning.
  void _dropSupersededRunningReasoning(CanonicalEvent incoming) {
    _events.removeWhere((existing) {
      if (existing.kind != EventKind.reasoning || existing.status != EventStatus.running) {
        return false;
      }
      return _matchesModelStep(existing, incoming) ||
          (incoming.sessionId != null && existing.sessionId == incoming.sessionId);
    });
  }

  void _removeSupersededRunningStream(CanonicalEvent incoming) {
    _events.removeWhere((existing) {
      if (existing.id == incoming.id || existing.kind != incoming.kind || existing.status != EventStatus.running) {
        return false;
      }
      if (incoming.sessionId != null) {
        return existing.sessionId == incoming.sessionId;
      }
      if (incoming.runId != null) {
        return existing.runId == incoming.runId;
      }
      return true;
    });
  }

  void _completeThinkingStep({
    required String modelStepId,
    String? runId,
    String? sessionId,
  }) {
    for (var index = 0; index < _events.length; index++) {
      final event = _events[index];
      if ((event.kind != EventKind.thinking && event.kind != EventKind.reasoning) ||
          event.status != EventStatus.running ||
          event.modelStepId != modelStepId ||
          (runId != null && event.runId != runId) ||
          (sessionId != null && event.sessionId != sessionId)) {
        continue;
      }
      _events[index] = event.copyWith(status: EventStatus.done);
    }
  }

  bool _matchesModelStep(CanonicalEvent existing, CanonicalEvent terminal) {
    if (terminal.modelStepId != null) {
      return existing.modelStepId == terminal.modelStepId;
    }
    return terminal.runId != null && existing.runId == terminal.runId;
  }

  CanonicalEvent _merge(CanonicalEvent existing, CanonicalEvent incoming) {
    switch (incoming.kind) {
      case EventKind.thinking:
      case EventKind.reasoning:
        if (incoming.status == EventStatus.running) {
          return existing.copyWith(
            text: _mergeThinkingText(existing.text, incoming.text),
            status: EventStatus.running,
            timestamp: incoming.timestamp,
            runId: incoming.runId ?? existing.runId,
            modelStepId: incoming.modelStepId ?? existing.modelStepId,
          );
        }
        return existing.copyWith(
          text: incoming.text.isNotEmpty ? incoming.text : existing.text,
          status: incoming.status,
          timestamp: incoming.timestamp,
          runId: incoming.runId ?? existing.runId,
          modelStepId: incoming.modelStepId ?? existing.modelStepId,
        );

      case EventKind.toolCall:
        if (!_shouldApplyToolEvent(existing, incoming)) return existing;
        // tool_use seeds `name`/`input`, tool_result adds `output` and flips status.
        final merged = <String, dynamic>{...?existing.tool};
        incoming.tool?.forEach((k, v) {
          if (v != null) merged[k] = v;
        });
        return existing.copyWith(
          tool: merged,
          status: _mergedToolStatus(existing, incoming),
          timestamp: incoming.timestamp,
          sessionId: incoming.sessionId ?? existing.sessionId,
          runId: incoming.runId ?? existing.runId,
          modelStepId: incoming.modelStepId ?? existing.modelStepId,
          toolCallId: incoming.toolCallId ?? existing.toolCallId,
          eventId: incoming.eventId ?? existing.eventId,
          metadata: incoming.metadata != null ? {...?existing.metadata, ...incoming.metadata!} : existing.metadata,
        );

      case EventKind.finalAnswer:
        // Streaming final answers append; finalized replace.
        if (incoming.status == EventStatus.running) {
          return existing.copyWith(
            text: existing.text + incoming.text,
            status: EventStatus.running,
            timestamp: incoming.timestamp,
            runId: incoming.runId ?? existing.runId,
            model: incoming.model ?? existing.model,
            modelDisplay: incoming.modelDisplay ?? existing.modelDisplay,
            provider: incoming.provider ?? existing.provider,
            usage: incoming.usage ?? existing.usage,
            runtimeMs: incoming.runtimeMs ?? existing.runtimeMs,
            contextTokens: incoming.contextTokens ?? existing.contextTokens,
            thinkingMode: incoming.thinkingMode ?? existing.thinkingMode,
            reasoningLevel: incoming.reasoningLevel ?? existing.reasoningLevel,
            metadata: incoming.metadata ?? existing.metadata,
          );
        }
        return existing.copyWith(
          text: incoming.text.isNotEmpty ? incoming.text : existing.text,
          status: incoming.status,
          timestamp: incoming.timestamp,
          runId: incoming.runId ?? existing.runId,
          model: incoming.model ?? existing.model,
          modelDisplay: incoming.modelDisplay ?? existing.modelDisplay,
          provider: incoming.provider ?? existing.provider,
          usage: incoming.usage ?? existing.usage,
          runtimeMs: incoming.runtimeMs ?? existing.runtimeMs,
          contextTokens: incoming.contextTokens ?? existing.contextTokens,
          thinkingMode: incoming.thinkingMode ?? existing.thinkingMode,
          reasoningLevel: incoming.reasoningLevel ?? existing.reasoningLevel,
          metadata: incoming.metadata ?? existing.metadata,
        );

      default:
        if (existing.metadata?['compaction_event'] == true) {
          return incoming.copyWith(
            metadata: {...?existing.metadata, ...?incoming.metadata},
          );
        }
        return incoming;
    }
  }

  bool _shouldApplyCompactionLifecycle(
    CanonicalEvent existing,
    CanonicalEvent incoming,
  ) {
    final existingStatus = existing.metadata?['compaction_status']?.toString();
    final incomingStatus = incoming.metadata?['compaction_status']?.toString();
    final existingRank = _compactionLifecycleRank(existingStatus);
    final incomingRank = _compactionLifecycleRank(incomingStatus);
    if (existingRank == 2 && incomingRank == 2) {
      return existingStatus == incomingStatus;
    }
    return incomingRank >= existingRank;
  }

  int _compactionLifecycleRank(String? status) {
    return switch (status) {
      'completed' || 'failed' => 2,
      'started' => 1,
      _ => 0,
    };
  }

  int _findMatchingOptimisticUserMessage(CanonicalEvent incoming) {
    final requestId = incoming.metadata?['request_id']?.toString();
    if (requestId != null && requestId.isNotEmpty) {
      final byRequestId = _events.indexWhere(
        (event) =>
            event.kind == EventKind.userMessage &&
            event.metadata?['optimistic'] == true &&
            event.metadata?['request_id']?.toString() == requestId,
      );
      if (byRequestId != -1) return byRequestId;
    }

    var bestIndex = -1;
    var bestDeltaMs = 1 << 62;
    for (var i = 0; i < _events.length; i += 1) {
      final event = _events[i];
      if (event.kind != EventKind.userMessage) continue;
      if (event.metadata?['optimistic'] != true) continue;
      if (event.text != incoming.text) continue;
      if (event.sessionId != incoming.sessionId) continue;

      final deltaMs = event.timestamp.difference(incoming.timestamp).abs().inMilliseconds;
      if (deltaMs < bestDeltaMs && deltaMs <= const Duration(seconds: 30).inMilliseconds) {
        bestDeltaMs = deltaMs;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  String _mergeThinkingText(String existingText, String incomingText) {
    switch (_thinkingStreamMode) {
      case ThinkingStreamMode.delta:
        return existingText + incomingText;
      case ThinkingStreamMode.snapshot:
        return incomingText.isNotEmpty ? incomingText : existingText;
      case ThinkingStreamMode.auto:
        // Backward-compatible fallback while bridges adopt the explicit
        // capability. Supports delta ("A" -> "B") and cumulative snapshot
        // streams ("A" -> "AB").
        return _mergeStreamingText(existingText, incomingText);
    }
  }

  String _mergeStreamingText(String existingText, String incomingText) {
    if (incomingText.isEmpty) return existingText;
    if (existingText.isEmpty) return incomingText;
    if (incomingText == existingText) return existingText;
    if (incomingText.startsWith(existingText)) return incomingText;
    if (existingText.startsWith(incomingText)) return existingText;
    return existingText + incomingText;
  }

  EventStatus _advanceStatus(EventStatus current, EventStatus incoming) {
    return terminalStatusRank(incoming) >= terminalStatusRank(current) ? incoming : current;
  }

  EventStatus _mergedToolStatus(
    CanonicalEvent existing,
    CanonicalEvent incoming,
  ) {
    final hasVersionMetadata =
        existing.generation != null ||
        incoming.generation != null ||
        existing.revision != null ||
        incoming.revision != null;
    if (hasVersionMetadata && isNewerToolTerminalEvent(existing, incoming)) {
      return incoming.status;
    }
    return _advanceStatus(existing.status, incoming.status);
  }

  bool _shouldApplyToolEvent(
    CanonicalEvent existing,
    CanonicalEvent incoming,
  ) {
    if (incoming.status == EventStatus.running) {
      return existing.status == EventStatus.running;
    }
    if (existing.status == EventStatus.running) return true;

    final sameVersion = existing.generation == incoming.generation && existing.revision == incoming.revision;
    if (sameVersion && existing.revision != null) {
      return existing.status == incoming.status;
    }
    return isNewerToolTerminalEvent(existing, incoming);
  }

  void dispose() {}
}
