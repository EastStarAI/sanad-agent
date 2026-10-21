import 'dart:io';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import '../core/config.dart';
import '../core/constants.dart';
import '../core/di.dart';
import '../core/environment_hints.dart';
import '../evolution/scheduling/schedule_model.dart';

/// Three-tier system prompt assembler for the sanad-agent agent engine.
///
/// Inspired by the three-tier architecture, the system context is split into
/// three tiers ordered by how frequently they change. This ordering is critical
/// for **LLM prefix-cache efficiency**: stable content at the top allows the
/// provider (Anthropic, OpenAI) to reuse cached KV-states across turns,
/// reducing latency and cost.
///
/// ## Tiers (top → bottom in final prompt)
///
/// | Tier       | Changes when             | Contains                                  |
/// |------------|--------------------------|-------------------------------------------|
/// | `stable`   | Never during a session   | Agent identity (SOUL.md or base prompt)   |
/// | `context`  | Per session / workspace  | AGENTS.md, workspace path, skills         |
/// | `volatile` | Every turn               | Memory snapshot, date, session metadata   |
///
/// ## Usage
///
/// ```dart
/// final assembler = AgentContextAssembler(
///   identity: 'You are Sanad Agent...',
/// );
///
/// // Called once per session after workspace is known:
/// assembler.setContext(contextText);
///
/// // Called on every turn before building effectiveHistory:
/// assembler.setVolatile(memoryContext: '...');
///
/// final systemPrompt = assembler.assemble();
/// ```
///
/// The assembled string is a single coherent block. [AgentRunner] injects it
/// as a single `system` [Message] at position 0 of effectiveHistory — one
/// message, not four — which is more compatible with provider constraints and
/// easier to reason about.
class AgentContextAssembler {
  /// Creates an assembler.
  ///
  /// [identity] sets the stable tier explicitly (highest priority).
  /// If [identity] is omitted or empty:
  ///   1. `~/.sanad/SOUL.md` is loaded lazily on the first [assemble] call.
  ///   2. If SOUL.md does not exist, a built-in default identity is used.
  ///
  /// This means callers (CLI, daemon, sub-agents) do NOT need to call
  /// [addSystemMessage] at all — identity resolution is automatic.
  AgentContextAssembler({String? identity}) {
    if (identity != null && identity.trim().isNotEmpty) {
      _stableIdentity = identity.trim();
      _soulMdAttempted = true; // explicit identity wins; skip SOUL.md lookup
    }
  }

  // ── Stable tier ─────────────────────────────────────────────────────────
  // Resolved lazily on the first assemble() call to give SOUL.md a chance to
  // exist even when AgentRunner is constructed before ~/.sanad/ is initialised.
  String? _stableIdentity;
  bool _soulMdAttempted = false;

  // Default identity used when neither an explicit identity nor SOUL.md is
  // available. Keeps the agent from running with no persona at all.
  static const int _maxSoulChars = 20000;

  static const String _defaultIdentity =
      'You are Sanad Agent, an intelligent AI assistant running locally on the user\'s machine. '
      'You are helpful, knowledgeable, and direct. You assist the user with a wide range of tasks, '
      'including writing and editing code, executing actions via your tools, and analyzing local workspace files. '
      'You communicate clearly, admit uncertainty when appropriate, and prioritize being genuinely useful over being verbose. '
      'Be targeted, concise, and efficient in your exploration and investigations. '
      'Use tools whenever they improve correctness. Read the relevant file or context before editing it. '
      'Prefer concrete action and verification over long speculative planning. '
      'Write clean, reusable code and avoid unnecessary duplication.';
  String? _stableGuidance;

  // ── Context tier ─────────────────────────────────────────────────────────
  // Set once per session when the workspace becomes known; rebuilt only when
  // the user switches workspaces.
  String? _contextBlock;

  // ── Volatile tier ────────────────────────────────────────────────────────
  // Rebuilt on every turn. Not cached — always reflect the latest values.
  String? _memoryContext;
  String? _sessionId;
  String? _model;
  String? _provider;

  // ─────────────────────────────────────────────────────────────────────────

  /// Updates the stable identity explicitly.
  ///
  /// Calling this overrides SOUL.md for the lifetime of this assembler.
  /// Prefer letting SOUL.md handle identity automatically rather than calling
  /// this from entry points (CLI, daemon). Reserve for sub-agents that need a
  /// role-specific persona set programmatically.
  void setIdentity(String identity) {
    _stableIdentity = identity.trim().isEmpty ? null : identity.trim();
    _soulMdAttempted = true; // explicit identity wins; skip SOUL.md lookup
  }

  /// Sets extra stable guidance that should remain byte-stable for the full session.
  void setStableGuidance(String? guidance) {
    _stableGuidance = guidance?.trim().isEmpty == true
        ? null
        : guidance?.trim();
  }

  /// Sets the context tier (workspace-level instructions, AGENTS.md, skills).
  ///
  /// Call this once per session after [RuntimeContextBuilder] has produced
  /// its output. Pass `null` to clear (e.g. when no workspace is active).
  void setContext(String? context) {
    _contextBlock = context?.trim().isEmpty == true ? null : context?.trim();
  }

  /// Sets the volatile tier fields for the current turn.
  ///
  /// - [memoryContext]: Retrieved long-term memory snapshot.
  /// - [sessionId], [model], [provider]: Runtime metadata for the active turn.
  ///
  /// Both default to empty — pass only what is available.
  void setVolatile({
    String memoryContext = '',
    String? sessionId,
    String? model,
    String? provider,
  }) {
    _memoryContext = memoryContext.trim().isEmpty ? null : memoryContext.trim();
    _sessionId = sessionId?.trim().isEmpty == true ? null : sessionId?.trim();
    _model = model?.trim().isEmpty == true ? null : model?.trim();
    _provider = provider?.trim().isEmpty == true ? null : provider?.trim();
  }

  /// Clears the volatile runtime metadata (model/provider) so the next
  /// [assemble] call rebuilds it from fresh values. Called by AgentRunner
  /// after a per-session provider/model switch so the system prompt reflects
  /// the new route without waiting for the next [setVolatile] call.
  void invalidateVolatile() {
    _model = null;
    _provider = null;
  }

  /// Assembles the full system prompt from all three tiers.
  ///
  /// Returns `null` when all tiers are empty (rare; mostly in unit tests with
  /// no configuration). The returned string is intended for use as the content
  /// of a single `system` [Message].
  ///
  /// Order in the final string (top = highest priority for the model):
  ///
  /// ```
  /// [stable:   agent identity / SOUL.md]
  /// [context:  workspace + AGENTS.md + skills]
  /// [volatile: date + memory + runtime metadata]
  /// ```
  String? assemble() {
    // Lazy SOUL.md resolution: attempt once per assembler instance, on the
    // first assemble() call. This ensures the file is checked after the sanad
    // home directory is fully initialised, even if the assembler was
    // constructed very early (e.g. inside AgentRunner's constructor).
    if (!_soulMdAttempted) {
      _soulMdAttempted = true;
      _stableIdentity = _loadSoulMd() ?? _defaultIdentity;
    }

    final parts = <String>[];

    // Stable — never changes during a session. Placed first for prefix cache.
    if (_stableIdentity != null) parts.add(_stableIdentity!);
    if (_stableGuidance != null) parts.add(_stableGuidance!);
    final envHints = EnvironmentHints.build();
    if (envHints.isNotEmpty) {
      parts.add(envHints);
    }

    // Context — changes per workspace/session.
    if (_contextBlock != null) parts.add(_contextBlock!);

    // Volatile — changes every turn. Placed last so cacheable prefixes stay stable.
    final volatilePart = _buildVolatilePart();
    if (volatilePart != null) parts.add(volatilePart);

    if (parts.isEmpty) return null;
    return parts.join('\n\n');
  }

  /// The single per-turn date line (Task 112b, Decision B-D7).
  ///
  /// Date-only — NOT minute/second precision. A clock time would make the
  /// system message unique per call and break prefix caching, while a date
  /// still lets a long conversation see the current day. The date is taken in
  /// the schedule timezone (`SCHEDULE_TIMEZONE`, the same resolution scheduling
  /// uses) and labelled with that zone; an unsupported configured value falls
  /// back to `local` rather than failing context assembly.
  @visibleForTesting
  static String formatDateLine({DateTime? now, String? zoneName}) {
    final zone = _resolveDateZone(zoneName);
    final zoned = zone.toZoned((now ?? DateTime.now()).toUtc());
    final y = zoned.year.toString().padLeft(4, '0');
    final m = zoned.month.toString().padLeft(2, '0');
    final d = zoned.day.toString().padLeft(2, '0');
    return 'Date: $y-$m-$d (zone: ${zone.raw})';
  }

  static ScheduleZone _resolveDateZone(String? zoneName) {
    final configured =
        zoneName ??
        (getIt.isRegistered<Config>()
            ? getIt<Config>().scheduleTimezone
            : 'local');
    try {
      return ScheduleZone.parse(configured);
    } on ScheduleValidationException {
      // Warn once per distinct rejected value; the date line is rebuilt every
      // turn and must not repeat the warning.
      if (_warnedInvalidZones.add(configured)) {
        _logger.warning(
          'SCHEDULE_TIMEZONE "$configured" is not supported; using local. '
          'IANA zone names are not supported in this release; accepted forms '
          'are local or ±HH:MM.',
        );
      }
      return ScheduleZone.local();
    }
  }

  static final Logger _logger = Logger('AgentContextAssembler');
  static final Set<String> _warnedInvalidZones = {};

  /// Clears the once-per-value warning memory between tests.
  @visibleForTesting
  static void resetZoneWarningsForTesting() => _warnedInvalidZones.clear();

  // ── Private helpers ──────────────────────────────────────────────────────

  String? _buildVolatilePart() {
    final volatileParts = <String>[];

    volatileParts.add(formatDateLine());

    final runtimeLines = <String>[];
    if (_sessionId != null) runtimeLines.add('Session ID: $_sessionId');
    if (_model != null) runtimeLines.add('Model: $_model');
    if (_provider != null) runtimeLines.add('Provider: $_provider');
    if (runtimeLines.isNotEmpty) {
      volatileParts.add(runtimeLines.join('\n'));
    }

    if (_memoryContext != null) volatileParts.add(_memoryContext!);

    if (volatileParts.isEmpty) return null;
    return volatileParts.join('\n\n');
  }

  /// Attempts to load `SOUL.md` from `~/.sanad/SOUL.md`.
  ///
  /// SOUL.md is an optional user-editable file that overrides the default
  /// agent identity. If it exists and is non-empty, its content becomes the
  /// stable identity for this session.
  ///
  /// Returns `null` if the file does not exist or cannot be read.
  static String? _loadSoulMd() {
    try {
      final sanadHome = getSanadHome();
      final soulFile = File(p.join(sanadHome, 'SOUL.md'));
      if (!soulFile.existsSync()) return null;
      var content = soulFile.readAsStringSync().trim();
      if (content.length > _maxSoulChars) {
        content = _truncateHeadTail(content, _maxSoulChars, 'SOUL.md');
      }
      content = _sanitizeContent(content, 'SOUL.md');
      return content.isEmpty ? null : content;
    } catch (_) {
      return null;
    }
  }

  static String _sanitizeContent(String content, String filename) {
    final lower = content.toLowerCase();
    const injectionPatterns = [
      'ignore previous instructions',
      'ignore all instructions',
      'system prompt override',
      'you are now a',
    ];
    for (final pattern in injectionPatterns) {
      if (lower.contains(pattern)) {
        return '[SECURITY WARNING: Content from $filename was blocked because it contained potential prompt injection patterns. Content not loaded.]';
      }
    }
    return content;
  }

  static String _truncateHeadTail(
    String content,
    int maxChars,
    String filename,
  ) {
    if (content.length <= maxChars) {
      return content;
    }

    final markerTemplate =
        '\n\n[...truncated $filename: kept H+T of ${content.length} chars.]\n\n';
    final availableChars = maxChars - markerTemplate.length;
    if (availableChars <= 16) {
      return content.substring(0, maxChars);
    }

    final headChars = (availableChars * 0.7).floor();
    final tailChars = availableChars - headChars;
    final head = content.substring(0, headChars);
    final tail = content.substring(content.length - tailChars);
    final marker =
        '\n\n[...truncated $filename: kept $headChars+$tailChars of ${content.length} chars.]\n\n';
    return '$head$marker$tail';
  }
}
