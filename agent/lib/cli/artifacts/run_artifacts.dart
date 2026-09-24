import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

String _isoUtcMilliseconds(DateTime value) {
  final utc = value.toUtc();
  final milliseconds = utc.millisecond.toString().padLeft(3, '0');
  final base = utc.toIso8601String().split('.').first;
  return '$base.${milliseconds}Z';
}

/// Represents a timestamped lifecycle event in a one-shot or delegated run.
class RunLifecycleEvent {
  final String timestamp;
  final String type;
  final String sessionId;
  final Map<String, dynamic> data;

  const RunLifecycleEvent({
    required this.timestamp,
    required this.type,
    required this.sessionId,
    this.data = const {},
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp,
    'type': type,
    'session_id': sessionId,
    if (data.isNotEmpty) 'data': data,
  };

  factory RunLifecycleEvent.fromJson(Map<String, dynamic> json) {
    return RunLifecycleEvent(
      timestamp: json['timestamp'] as String? ?? '',
      type: json['type'] as String? ?? 'unknown',
      sessionId: json['session_id'] as String? ?? '',
      data: json['data'] is Map<String, dynamic>
          ? json['data'] as Map<String, dynamic>
          : json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : const {},
    );
  }
}

/// Versioned machine-readable result contract written to `result.json`.
class RunResultArtifact {
  final String schema;
  final String version;
  final String sessionId;
  final String? workspaceId;
  final String? executionRoot;
  final String? provider;
  final String? model;
  final String status;
  final int exitCode;
  final String startedAt;
  final String? endedAt;
  final int? durationMs;
  final String? text;
  final String? error;
  final String? cause;
  final String? stateSince;
  final String? lastProgressAt;
  final Map<String, dynamic>? pendingIntervention;
  final Map<String, dynamic>? terminalOutput;

  const RunResultArtifact({
    this.schema = 'https://sanad.dev/schemas/run-result-v1.json',
    this.version = '1.0.0',
    required this.sessionId,
    this.workspaceId,
    this.executionRoot,
    this.provider,
    this.model,
    required this.status,
    this.exitCode = 0,
    required this.startedAt,
    this.endedAt,
    this.durationMs,
    this.text,
    this.error,
    this.cause,
    this.stateSince,
    this.lastProgressAt,
    this.pendingIntervention,
    this.terminalOutput,
  });

  bool get isRunning => status == 'running';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
  bool get isTimeout => status == 'timeout';
  bool get isInterrupted => status == 'interrupted';
  bool get isCancelled => status == 'cancelled';
  bool get isTerminal =>
      status == 'completed' ||
      status == 'failed' ||
      status == 'timeout' ||
      status == 'interrupted' ||
      status == 'cancelled';
  bool get isNeedsIntervention =>
      status == 'needs_input' || status == 'needs_permission';
  bool get isBlocked => status == 'blocked';
  bool get isWaiting => status == 'waiting';
  bool get isResuming => status == 'resuming';

  static String classifyCause({required String code, required String message}) {
    // Runtime notices already carry RuntimeFailureReason's structured wire
    // value. Do not reinterpret prose: generic words such as "timeout" or
    // "connection" can describe a local observer without identifying the
    // provider failure class.
    final normalizedCode = code.trim().toLowerCase();
    return switch (normalizedCode) {
      'timeout' || 'provider_timeout' => 'provider_timeout',
      'billing' || 'quota' || 'provider_quota' => 'provider_quota',
      'rate_limit' || 'upstream_rate_limit' => 'rate_limit',
      'network_error' => 'network_error',
      'auth' || 'auth_error' => 'auth_error',
      '' => 'unknown',
      _ => normalizedCode,
    };
  }

  RunResultArtifact copyWith({
    String? status,
    int? exitCode,
    String? endedAt,
    int? durationMs,
    String? text,
    String? error,
    String? provider,
    String? model,
    String? cause,
    String? stateSince,
    String? lastProgressAt,
    bool clearCause = false,
    Map<String, dynamic>? pendingIntervention,
    Map<String, dynamic>? terminalOutput,
    bool clearPendingIntervention = false,
  }) {
    return RunResultArtifact(
      schema: schema,
      version: version,
      sessionId: sessionId,
      workspaceId: workspaceId,
      executionRoot: executionRoot,
      provider: provider ?? this.provider,
      model: model ?? this.model,
      status: status ?? this.status,
      exitCode: exitCode ?? this.exitCode,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      durationMs: durationMs ?? this.durationMs,
      text: text ?? this.text,
      error: error ?? this.error,
      cause: clearCause ? null : (cause ?? this.cause),
      stateSince: stateSince ?? this.stateSince,
      lastProgressAt: lastProgressAt ?? this.lastProgressAt,
      pendingIntervention: clearPendingIntervention
          ? null
          : (pendingIntervention ?? this.pendingIntervention),
      terminalOutput: terminalOutput ?? this.terminalOutput,
    );
  }

  Map<String, dynamic> toJson() => {
    '\$schema': schema,
    'version': version,
    'session_id': sessionId,
    if (workspaceId != null) 'workspace_id': workspaceId,
    if (executionRoot != null) 'execution_root': executionRoot,
    if (provider != null) 'provider': provider,
    if (model != null) 'model': model,
    'status': status,
    'exit_code': exitCode,
    'started_at': startedAt,
    if (endedAt != null) 'ended_at': endedAt,
    if (durationMs != null) 'duration_ms': durationMs,
    if (text != null) 'text': text,
    if (error != null) 'error': error,
    if (cause != null) 'cause': cause,
    if (stateSince != null) 'state_since': stateSince,
    if (lastProgressAt != null) 'last_progress_at': lastProgressAt,
    if (pendingIntervention != null)
      'pending_intervention': pendingIntervention,
    if (terminalOutput != null) 'terminal_output': terminalOutput,
  };

  factory RunResultArtifact.fromJson(Map<String, dynamic> json) {
    return RunResultArtifact(
      schema:
          json['\$schema'] as String? ??
          'https://sanad.dev/schemas/run-result-v1.json',
      version: json['version'] as String? ?? '1.0.0',
      sessionId: json['session_id'] as String? ?? '',
      workspaceId: json['workspace_id'] as String?,
      executionRoot: json['execution_root'] as String?,
      provider: json['provider'] as String?,
      model: json['model'] as String?,
      status: json['status'] as String? ?? 'unknown',
      exitCode: json['exit_code'] as int? ?? 0,
      startedAt: json['started_at'] as String? ?? '',
      endedAt: json['ended_at'] as String?,
      durationMs: json['duration_ms'] as int?,
      text: json['text'] as String?,
      error: json['error'] as String?,
      cause: json['cause'] as String?,
      stateSince: json['state_since'] as String?,
      lastProgressAt: json['last_progress_at'] as String?,
      pendingIntervention: json['pending_intervention'] is Map
          ? Map<String, dynamic>.from(json['pending_intervention'] as Map)
          : null,
      terminalOutput: json['terminal_output'] is Map
          ? Map<String, dynamic>.from(json['terminal_output'] as Map)
          : null,
    );
  }
}

/// Manages serialized result publication and event logging in the destination directory.
class RunArtifactStore {
  final String outputDirectory;

  const RunArtifactStore(this.outputDirectory);

  String get resultPath => p.join(outputDirectory, 'result.json');
  String get eventsPath => p.join(outputDirectory, 'events.jsonl');

  /// Ensures output directory exists.
  void ensureDirectory() {
    final dir = Directory(outputDirectory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  /// Publishes [result] through a complete temporary file before replacement.
  Future<void> writeResult(RunResultArtifact result) async {
    ensureDirectory();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(result.toJson());
    final tempFile = File(p.join(outputDirectory, 'result.json.tmp'));
    final targetFile = File(resultPath);

    await tempFile.writeAsString('$jsonStr\n', flush: true);
    if (targetFile.existsSync()) {
      targetFile.deleteSync();
    }
    await tempFile.rename(targetFile.path);
  }

  /// Appends a [RunLifecycleEvent] as a line in `events.jsonl`.
  Future<void> appendEvent(RunLifecycleEvent event) async {
    ensureDirectory();
    final file = File(eventsPath);
    final eventJson = jsonEncode(event.toJson());
    await file.writeAsString(
      '$eventJson\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Reads current `result.json` if it exists.
  Future<RunResultArtifact?> readResult() async {
    final file = File(resultPath);
    if (!file.existsSync()) return null;
    final content = await file.readAsString();
    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic>) {
      return RunResultArtifact.fromJson(decoded);
    }
    return null;
  }

  /// Reads all events from `events.jsonl` if it exists.
  Future<List<RunLifecycleEvent>> readEvents() async {
    final file = File(eventsPath);
    if (!file.existsSync()) return const [];
    final lines = await file.readAsLines();
    return lines
        .where((line) => line.trim().isNotEmpty)
        .map(
          (line) => RunLifecycleEvent.fromJson(
            Map<String, dynamic>.from(jsonDecode(line) as Map),
          ),
        )
        .toList();
  }
}

/// Serializes all state transitions and event emissions through a strictly sequential async queue.
/// Guarantees that:
/// 1. File writes and event appends never race on `result.json.tmp`.
/// 2. Once a terminal state is reached, no preceding or in-flight non-terminal transition can overwrite it.
/// 3. All pending writes can be fully drained before process exit.
class RunArtifactCoordinator {
  final RunArtifactStore? store;
  final bool streamEvents;
  final StringSink? outSink;
  final String sessionId;
  final String? workspaceId;
  final String? executionRoot;
  final String? initialProvider;
  final String? initialModel;
  final DateTime startTime;

  Future<void> _queue = Future.value();
  bool _isTerminal = false;
  DateTime? _lastProgressWriteAt;
  late RunResultArtifact _currentArtifact;

  RunArtifactCoordinator({
    this.store,
    this.streamEvents = false,
    this.outSink,
    required this.sessionId,
    this.workspaceId,
    this.executionRoot,
    this.initialProvider,
    this.initialModel,
    DateTime? startTime,
  }) : startTime = startTime ?? DateTime.now().toUtc() {
    _currentArtifact = RunResultArtifact(
      sessionId: sessionId,
      workspaceId: workspaceId,
      executionRoot: executionRoot,
      provider: initialProvider,
      model: initialModel,
      status: 'running',
      exitCode: 0,
      startedAt: _isoUtcMilliseconds(this.startTime),
    );
  }

  bool get isTerminal => _isTerminal;
  RunResultArtifact get currentArtifact => _currentArtifact;

  Future<void> _enqueue(Future<void> Function() action) {
    final completer = Completer<void>();
    _queue = _queue.catchError((_) {}).then((_) async {
      try {
        await action();
        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  /// Initial event and artifact write.
  Future<void> recordInitial() {
    return _enqueue(() async {
      if (store != null) {
        await store!.writeResult(_currentArtifact);
      }
      await _emitEvent('running', {
        if (workspaceId != null) 'workspace_id': workspaceId,
        if (executionRoot != null) 'execution_root': executionRoot,
      });
    });
  }

  /// Non-terminal suspension awaiting user input or permission.
  Future<void> recordPendingIntervention({
    required String kind,
    required String requestId,
    String? toolName,
    List<dynamic>? questions,
  }) {
    return _enqueue(() async {
      if (_isTerminal || _currentArtifact.isTerminal) return;
      final interventionData = <String, dynamic>{
        'kind': kind,
        'session_id': sessionId,
        'request_id': requestId,
        'tool_name': ?toolName,
        if (questions != null && questions.isNotEmpty) 'questions': questions,
      };

      final now = _isoUtcMilliseconds(DateTime.now());
      _currentArtifact = _currentArtifact.copyWith(
        status: kind,
        stateSince: now,
        pendingIntervention: interventionData,
      );

      if (store != null) {
        await store!.writeResult(_currentArtifact);
      }
      await _emitEvent(kind, interventionData);
    });
  }

  /// Resumption following external intervention.
  Future<void> recordResumed() {
    return _enqueue(() async {
      if (_isTerminal ||
          _currentArtifact.isTerminal ||
          !_currentArtifact.isNeedsIntervention) {
        return;
      }
      final now = _isoUtcMilliseconds(DateTime.now());
      _currentArtifact = _currentArtifact.copyWith(
        status: 'running',
        stateSince: now,
        lastProgressAt: now,
        clearPendingIntervention: true,
      );
      _lastProgressWriteAt = DateTime.parse(now);

      if (store != null) {
        await store!.writeResult(_currentArtifact);
      }
      await _emitEvent('resumed', const {'status': 'running'});
    });
  }

  /// Non-terminal runtime notice (e.g. blocked, waiting, resuming).
  Future<void> recordRuntimeNotice({
    required String status,
    required String code,
    required String message,
    String? provider,
    String? model,
    String? cause,
  }) {
    return _enqueue(() async {
      if (_isTerminal || _currentArtifact.isTerminal) return;
      final now = _isoUtcMilliseconds(DateTime.now());
      final effectiveCause =
          cause ??
          RunResultArtifact.classifyCause(code: code, message: message);
      final isNewState =
          _currentArtifact.status != status ||
          _currentArtifact.cause != effectiveCause;
      final noticeData = <String, dynamic>{
        'status': status,
        'code': code,
        'cause': effectiveCause,
        'message': message,
        'session_id': sessionId,
        'provider': ?provider,
        'model': ?model,
      };

      _currentArtifact = _currentArtifact.copyWith(
        status: status,
        cause: effectiveCause,
        stateSince: isNewState ? now : _currentArtifact.stateSince,
        provider: provider,
        model: model,
      );

      if (store != null) {
        await store!.writeResult(_currentArtifact);
      }
      await _emitEvent(status, noticeData);
    });
  }

  /// Records active progress (assistant chunk, tool call/result, reasoning).
  Future<void> recordProgress() {
    return _enqueue(() async {
      if (_isTerminal || _currentArtifact.isTerminal) return;
      final nowDate = DateTime.now().toUtc();
      final now = _isoUtcMilliseconds(nowDate);
      final wasNonterminalBlockedOrWaiting =
          _currentArtifact.status == 'blocked' ||
          _currentArtifact.status == 'waiting' ||
          _currentArtifact.status == 'resuming' ||
          _currentArtifact.isNeedsIntervention;
      if (!wasNonterminalBlockedOrWaiting &&
          _lastProgressWriteAt != null &&
          nowDate.difference(_lastProgressWriteAt!) <
              const Duration(seconds: 5)) {
        return;
      }
      _lastProgressWriteAt = nowDate;

      _currentArtifact = _currentArtifact.copyWith(
        status: 'running',
        lastProgressAt: now,
        stateSince: wasNonterminalBlockedOrWaiting
            ? now
            : _currentArtifact.stateSince,
        clearCause: wasNonterminalBlockedOrWaiting,
        clearPendingIntervention: wasNonterminalBlockedOrWaiting,
      );

      if (store != null) {
        await store!.writeResult(_currentArtifact);
      }
      if (wasNonterminalBlockedOrWaiting) {
        await _emitEvent('resumed', const {'status': 'running'});
      }
    });
  }

  /// Terminal execution outcome (completed, failed, timeout, interrupted, cancelled).
  /// Terminal state is latched immediately so no further non-terminal updates can be queued.
  Future<void> recordTerminal({
    required int exitCode,
    required String status,
    String? text,
    String? error,
    String? finalModel,
    String? finalProvider,
    Map<String, dynamic>? usage,
  }) {
    return _enqueue(() async {
      if (_isTerminal || _currentArtifact.isTerminal) return;
      final endTime = DateTime.now().toUtc();
      final durationMs = endTime.difference(startTime).inMilliseconds;

      final effectiveModel = finalModel ?? initialModel;
      final effectiveProvider = finalProvider ?? initialProvider;

      final safeTerminalEnvelope = <String, dynamic>{
        'session_id': sessionId,
        'status': status,
        'exit_code': exitCode,
        if (text != null && text.isNotEmpty) 'text': text,
        if (error != null && error.isNotEmpty) 'error': error,
        'model': ?effectiveModel,
        'provider': ?effectiveProvider,
        if (usage != null && usage.isNotEmpty) 'usage': usage,
      };

      final terminalArtifact = _currentArtifact.copyWith(
        status: status,
        exitCode: exitCode,
        endedAt: _isoUtcMilliseconds(endTime),
        durationMs: durationMs,
        text: text,
        error: error,
        model: effectiveModel,
        provider: effectiveProvider,
        clearPendingIntervention: true,
        terminalOutput: safeTerminalEnvelope,
      );

      if (store != null) {
        await store!.writeResult(terminalArtifact);
      }

      // Once the terminal result is durably published, latch it before the
      // separately fallible lifecycle event emission. A failed result write
      // remains retryable; a failed event append can never reopen the run.
      _currentArtifact = terminalArtifact;
      _isTerminal = true;

      await _emitEvent(status, {
        'exit_code': exitCode,
        'duration_ms': durationMs,
        if (error != null && error.isNotEmpty) 'error': error,
      });
    });
  }

  Future<void> _emitEvent(String type, Map<String, dynamic> data) async {
    final event = RunLifecycleEvent(
      timestamp: _isoUtcMilliseconds(DateTime.now()),
      type: type,
      sessionId: sessionId,
      data: data,
    );
    if (streamEvents && outSink != null) {
      outSink!.writeln(jsonEncode(event.toJson()));
    }
    if (store != null) {
      await store!.appendEvent(event);
    }
  }

  /// Drains all pending artifact writes and event flushes before returning.
  Future<void> drain() async {
    await _queue.catchError((_) {});
  }
}
