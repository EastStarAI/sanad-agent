/// Per-request reasoning replay policy for OpenAI-compatible Chat routes
/// (Task 116 D1–D3).
///
/// Canonical history is never rewritten. Each request projects every
/// assistant message for its own destination route:
/// - reasoning or opaque state replays only to the exact same provider
///   instance, protocol, endpoint and model ([ProviderStateProvenance]);
/// - foreign or unrecorded origin is never copied, padded or relabelled;
/// - a route whose models.dev entry declares `interleaved.field:
///   reasoning_content` applies the probe-decided [ReplayCell] table, whose
///   conservative default sends exactly what was recorded.
library;

import '../../core/models/llm_provider_state.dart';
import '../../core/models/message.dart';
import '../../core/provider_thinking/native_thinking_directive.dart';
import 'provider_history_projection_exception.dart';

/// How the producing response delivered `reasoning_content` (D1).
enum ReasoningFieldObservation {
  string('string'),
  explicitNull('null'),
  absent('absent');

  final String wire;
  const ReasoningFieldObservation(this.wire);

  static ReasoningFieldObservation? parse(Object? raw) {
    for (final value in values) {
      if (value.wire == raw) return value;
    }
    return null;
  }

  /// Observation for one decoded message or delta payload.
  static ReasoningFieldObservation of(Map<String, dynamic> payload) {
    if (!payload.containsKey(ProviderStateProvenance.reasoningContentKey)) {
      return absent;
    }
    return payload[ProviderStateProvenance.reasoningContentKey] == null
        ? explicitNull
        : string;
  }

  /// Folds stream deltas: any string wins, then an explicit null.
  ReasoningFieldObservation merge(ReasoningFieldObservation next) {
    if (this == string || next == string) return string;
    if (this == explicitNull || next == explicitNull) return explicitNull;
    return absent;
  }
}

/// Additive provenance keys stamped into adapter-owned provider state data.
/// They never change the namespace or issuer string.
abstract final class ProviderStateProvenance {
  static const issuerModelKey = 'issuer_model';
  static const reasoningFieldKey = 'reasoning_field';
  static const reasoningContentKey = 'reasoning_content';
  static const reasoningDetailsKey = 'reasoning_details';

  /// The model that produced [message]: the typed stamp first, then the
  /// frozen per-step `context_usage.model_id`, then the legacy mutable
  /// `metadata.model`. Returns `null` when no provenance exists.
  static String? recordedModel(Message message) {
    final stamped = message.providerState?.data[issuerModelKey];
    if (stamped is String && stamped.isNotEmpty) return stamped;
    final metadata = message.metadata;
    final contextUsage = metadata?['context_usage'];
    final snapshotModel = contextUsage is Map
        ? contextUsage['model_id']?.toString()
        : null;
    if (snapshotModel != null && snapshotModel.isNotEmpty) {
      return snapshotModel;
    }
    final legacy = metadata?['model']?.toString();
    return legacy == null || legacy.isEmpty ? null : legacy;
  }

  /// Whether [state] was minted by exactly this namespace, issuer and model.
  /// A missing recorded model is foreign: unknown provenance never replays.
  static bool isSameRoute(
    Message message, {
    required String namespace,
    required String issuer,
    required String resolvedModel,
    String Function(String model)? normalizeModel,
  }) {
    final state = message.providerState;
    if (state == null ||
        state.namespace != namespace ||
        state.issuer != issuer) {
      return false;
    }
    final recorded = recordedModel(message);
    if (recorded == null) return false;
    final normalized = normalizeModel == null
        ? recorded
        : normalizeModel(recorded);
    return normalized == resolvedModel;
  }
}

/// Probe-relevant history shapes on a route that requires a reasoning echo.
enum ReplayCell {
  /// Same route, provider returned `reasoning_content: ""` (probe P1).
  sameRouteEmpty,

  /// Same route, provider returned no `reasoning_content` key (probe P2).
  sameRouteAbsent,

  /// Same route, provider returned `reasoning_content: null` (probe P3).
  sameRouteNull,

  /// Foreign or unrecorded tool-call turn before the current user turn (P4).
  foreignEarlierTurn,

  /// Foreign or unrecorded tool-call turn inside the current user turn (P5).
  foreignCurrentTurn,
}

/// [asRecorded] sends exactly what was recorded (omitting what is absent or
/// foreign); [reject] raises [ProviderHistoryProjectionException] pre-dispatch.
enum ReplayDecision { asRecorded, reject }

/// One assistant message's reasoning wire fields for this request.
final class ChatReasoningReplay {
  final bool emitContent;
  final Object? content;
  final List<dynamic>? details;

  const ChatReasoningReplay({
    this.emitContent = false,
    this.content,
    this.details,
  });

  static const none = ChatReasoningReplay();

  void applyTo(Map<String, dynamic> wire) {
    if (details != null) {
      wire[ProviderStateProvenance.reasoningDetailsKey] = details;
    }
    if (emitContent) {
      wire[ProviderStateProvenance.reasoningContentKey] = content;
    }
  }
}

class ChatReasoningReplayPolicy {
  /// Echo field this table governs (models.dev `interleaved.field`).
  static const echoField = ProviderStateProvenance.reasoningContentKey;

  /// Conservative default until live probes P1–P5 decide each cell: send
  /// exactly what was recorded. A probe outcome is a one-line change here
  /// (all echo-required routes) or in [routeOverrides] (one exact route).
  static const Map<ReplayCell, ReplayDecision> defaultDecisions = {
    ReplayCell.sameRouteEmpty: ReplayDecision.asRecorded, // P1
    ReplayCell.sameRouteAbsent: ReplayDecision.asRecorded, // P2
    ReplayCell.sameRouteNull: ReplayDecision.asRecorded, // P3
    ReplayCell.foreignEarlierTurn: ReplayDecision.asRecorded, // P4
    ReplayCell.foreignCurrentTurn: ReplayDecision.asRecorded, // P5
  };

  /// Exact-route data overrides keyed `<models.dev vendor>/<model>`. Empty
  /// until a probe establishes a route-specific outcome.
  static const Map<String, Map<ReplayCell, ReplayDecision>> routeOverrides = {};

  final Map<ReplayCell, ReplayDecision> decisions;
  final Map<String, Map<ReplayCell, ReplayDecision>> overrides;

  const ChatReasoningReplayPolicy({
    this.decisions = defaultDecisions,
    this.overrides = routeOverrides,
  });

  /// Reads the destination's echo field from its exact models.dev entry.
  static String? interleavedField(Map<String, dynamic>? modelsDevEntry) {
    final interleaved = modelsDevEntry?['interleaved'];
    if (interleaved is! Map) return null;
    final field = interleaved['field'];
    return field is String && field.isNotEmpty ? field : null;
  }

  /// Whether [directive] explicitly turns thinking off for this request.
  static bool thinkingDisabled(NativeThinkingDirective? directive) =>
      switch (directive) {
        ThinkingToggleDirective(:final enabled) => !enabled,
        ChatTemplateBooleanDirective(:final value) => !value,
        OpenAiEffortDirective(:final effort) => effort == 'none',
        NativeThinkingEffortDirective(:final effort) => effort == 'none',
        _ => false,
      };

  ReplayDecision decisionFor(ReplayCell cell, {String? routeKey}) =>
      overrides[routeKey]?[cell] ??
      decisions[cell] ??
      ReplayDecision.asRecorded;

  /// Projects reasoning replay for every assistant message in [history].
  ///
  /// [enforce] is false only for wire measurement, which must yield a real
  /// as-recorded estimate instead of an unknown measurement; dispatch and the
  /// summarizer always enforce, so rejection happens before any HTTP call.
  Map<Message, ChatReasoningReplay> plan(
    List<Message> history, {
    required String namespace,
    required String issuer,
    required String resolvedModel,
    required String route,
    String? routeKey,
    String? routeEchoField,
    NativeThinkingDirective? thinkingDirective,
    String Function(String model)? normalizeModel,
    bool enforce = true,
  }) {
    final result = Map<Message, ChatReasoningReplay>.identity();
    final echoRequired = routeEchoField == echoField;
    final mayReject =
        enforce && echoRequired && !thinkingDisabled(thinkingDirective);
    final currentTurnStart = history.lastIndexWhere(
      (message) => message.role == MessageRole.user,
    );
    var foreignRejected = 0;
    var sameRouteRejected = 0;

    for (var index = 0; index < history.length; index++) {
      final message = history[index];
      if (message.role != MessageRole.assistant) continue;
      final sameRoute = ProviderStateProvenance.isSameRoute(
        message,
        namespace: namespace,
        issuer: issuer,
        resolvedModel: resolvedModel,
        normalizeModel: normalizeModel,
      );
      final hasToolCalls = message.toolCalls?.isNotEmpty ?? false;
      final replay = sameRoute
          ? _recorded(message.providerState!, echoRequired: echoRequired)
          : ChatReasoningReplay.none;
      result[message] = replay;
      if (!echoRequired || !hasToolCalls) continue;

      final cell = sameRoute
          ? _sameRouteCell(message.providerState!)
          : (index > currentTurnStart
                ? ReplayCell.foreignCurrentTurn
                : ReplayCell.foreignEarlierTurn);
      if (cell == null || !mayReject) continue;
      if (decisionFor(cell, routeKey: routeKey) != ReplayDecision.reject) {
        continue;
      }
      if (sameRoute) {
        sameRouteRejected++;
      } else {
        foreignRejected++;
      }
    }

    if (foreignRejected > 0) {
      throw ProviderHistoryProjectionException(
        route: route,
        reasonCode:
            ProviderHistoryProjectionException.foreignToolTurnRequiresReasoning,
        affectedCount: foreignRejected,
      );
    }
    if (sameRouteRejected > 0) {
      throw ProviderHistoryProjectionException(
        route: route,
        reasonCode:
            ProviderHistoryProjectionException.sameRouteReasoningUnrecoverable,
        affectedCount: sameRouteRejected,
      );
    }
    return result;
  }

  static ChatReasoningReplay _recorded(
    LLMProviderState state, {
    required bool echoRequired,
  }) {
    final data = state.data;
    final details = data[ProviderStateProvenance.reasoningDetailsKey];
    if (data.containsKey(ProviderStateProvenance.reasoningContentKey)) {
      return ChatReasoningReplay(
        emitContent: true,
        content: data[ProviderStateProvenance.reasoningContentKey],
        details: details is List ? details : null,
      );
    }
    // A recorded explicit null is echoed only to a route that declares the
    // field; strict routes never receive a reasoning key they did not send.
    final recordedNull =
        ReasoningFieldObservation.parse(
          data[ProviderStateProvenance.reasoningFieldKey],
        ) ==
        ReasoningFieldObservation.explicitNull;
    return ChatReasoningReplay(
      emitContent: echoRequired && recordedNull,
      details: details is List ? details : null,
    );
  }

  static ReplayCell? _sameRouteCell(LLMProviderState state) {
    final data = state.data;
    if (data.containsKey(ProviderStateProvenance.reasoningContentKey)) {
      final value = data[ProviderStateProvenance.reasoningContentKey];
      return value is String && value.isEmpty
          ? ReplayCell.sameRouteEmpty
          : null;
    }
    return ReasoningFieldObservation.parse(
              data[ProviderStateProvenance.reasoningFieldKey],
            ) ==
            ReasoningFieldObservation.explicitNull
        ? ReplayCell.sameRouteNull
        : ReplayCell.sameRouteAbsent;
  }
}
