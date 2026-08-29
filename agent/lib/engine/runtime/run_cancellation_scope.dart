import 'dart:async';

/// Why an active run entered cancellation.
enum RunCancellationReason { userStop, timeout, shutdown, superseded }

/// Lifecycle of a run-scoped cancellation owner.
enum RunCancellationState {
  active,
  cancelling,
  cancelled,
  cleanupFailed,
  completed,
}

/// Typed cleanup result for one registered resource.
enum RunCancellationResourceOutcome {
  cancelled,
  timedOut,
  cleanupFailed,
  released,
}

/// Report for one resource that participated in cleanup.
class RunCancellationResourceReport {
  final String label;
  final RunCancellationResourceOutcome outcome;
  final Object? error;

  const RunCancellationResourceReport({
    required this.label,
    required this.outcome,
    this.error,
  });
}

/// Terminal cancellation report for one run scope.
class RunCancellationReport {
  final RunCancellationReason reason;
  final RunCancellationState finalState;
  final DateTime acceptedAt;
  final DateTime? completedAt;
  final List<RunCancellationResourceReport> resources;
  final bool cleanupDeadlineExceeded;

  const RunCancellationReport({
    required this.reason,
    required this.finalState,
    required this.acceptedAt,
    required this.completedAt,
    required this.resources,
    required this.cleanupDeadlineExceeded,
  });
}

/// Handle returned from [RunCancellationScope.register]. [release] removes the
/// registration from future cleanup without running its callback.
class RunCancellationResourceHandle {
  final RunCancellationScope _scope;
  final String _registrationId;
  bool _released = false;

  RunCancellationResourceHandle._(this._scope, this._registrationId);

  bool get isReleased => _released;

  void release() {
    if (_released) return;
    _released = true;
    _scope._releaseRegistration(_registrationId);
  }
}

class _ResourceRegistration {
  final String label;
  final Future<void> Function() cleanup;
  bool released = false;
  bool cleanupStarted = false;
  bool cleanupCompleted = false;
  Object? cleanupError;
  Future<void>? cleanupFuture;

  _ResourceRegistration({required this.label, required this.cleanup});
}

/// Run-owned cancellation primitive shared by provider, tool, and wait layers.
///
/// Invalidation closes publication synchronously. [cancel] is idempotent and
/// joins one bounded cleanup operation for every non-released registration.
class RunCancellationScope {
  static const defaultCleanupDeadline = Duration(seconds: 5);

  final String sessionId;
  final String runId;
  final String? workItemId;
  final int generation;

  RunCancellationState _state = RunCancellationState.active;
  bool _publicationOpen = true;
  RunCancellationReason? _reason;
  DateTime? _acceptedAt;
  RunCancellationReport? _report;
  final Completer<void> _cancelledSignal = Completer<void>();

  final Map<String, _ResourceRegistration> _registrations = {};
  final Map<String, RunCancellationResourceReport> _resourceReports = {};
  int _registrationCounter = 0;
  Future<RunCancellationReport>? _cancelFuture;

  RunCancellationScope({
    required this.sessionId,
    required this.runId,
    required this.workItemId,
    required this.generation,
  });

  RunCancellationState get state => _state;
  RunCancellationReason? get reason => _reason;
  RunCancellationReport? get report => _report;

  /// Completes when publication is invalidated or cancel starts.
  Future<void> get whenCancelled => _cancelledSignal.future;

  bool get isPublicationOpen =>
      _publicationOpen && _state == RunCancellationState.active;

  bool get isCancellationTerminal =>
      _state == RunCancellationState.cancelled ||
      _state == RunCancellationState.cleanupFailed ||
      _state == RunCancellationState.completed;

  /// Closes publication immediately. Safe to call multiple times.
  void invalidate({
    RunCancellationReason reason = RunCancellationReason.userStop,
  }) {
    _publicationOpen = false;
    _reason ??= reason;
    _acceptedAt ??= DateTime.now();
    if (!_cancelledSignal.isCompleted) {
      _cancelledSignal.complete();
    }
  }

  /// Registers a cleanup callback. Late registration after cancellation starts
  /// runs cleanup once for that resource.
  RunCancellationResourceHandle register(
    String label,
    Future<void> Function() cleanup,
  ) {
    final id = 'reg_${_registrationCounter++}';
    final registration = _ResourceRegistration(label: label, cleanup: cleanup);
    _registrations[id] = registration;

    if (_state == RunCancellationState.cancelling) {
      _startRegistrationCleanup(id, registration);
    } else if (_state == RunCancellationState.cancelled ||
        _state == RunCancellationState.cleanupFailed) {
      // A resource can finish starting in the same event-loop turn that Stop
      // terminalizes an otherwise empty scope. It is too late to amend the
      // terminal report, but the resource must still be cleaned up once.
      unawaited(_startRegistrationCleanup(id, registration));
    }

    return RunCancellationResourceHandle._(this, id);
  }

  /// Marks a naturally completed run without running registered cleanups.
  void markCompleted() {
    _publicationOpen = false;
    if (_state == RunCancellationState.active) {
      _state = RunCancellationState.completed;
    }
  }

  /// Idempotent cancellation entry point for Stop and watchdog paths.
  Future<RunCancellationReport> cancel({
    RunCancellationReason reason = RunCancellationReason.userStop,
    Duration cleanupDeadline = defaultCleanupDeadline,
  }) {
    invalidate(reason: reason);
    final existing = _cancelFuture;
    if (existing != null) {
      return existing;
    }
    if (_report != null) {
      return Future.value(_report);
    }

    _state = RunCancellationState.cancelling;
    _cancelFuture = _executeCleanup(cleanupDeadline);
    return _cancelFuture!;
  }

  void _releaseRegistration(String registrationId) {
    final registration = _registrations[registrationId];
    if (registration == null || registration.released) {
      return;
    }
    registration.released = true;
    _registrations.remove(registrationId);
  }

  Future<RunCancellationReport> _executeCleanup(
    Duration cleanupDeadline,
  ) async {
    final acceptedAt = _acceptedAt ?? DateTime.now();
    final reason = _reason ?? RunCancellationReason.userStop;
    final stopwatch = Stopwatch()..start();
    var deadlineExceeded = false;

    while (true) {
      final pending = Map<String, _ResourceRegistration>.from(_registrations)
        ..removeWhere((_, registration) => registration.released);
      if (pending.isEmpty) {
        break;
      }

      final remaining = cleanupDeadline - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        deadlineExceeded = true;
        break;
      }

      try {
        await Future.wait(
          pending.entries.map(
            (entry) => _startRegistrationCleanup(entry.key, entry.value),
          ),
        ).timeout(remaining);
      } on TimeoutException {
        deadlineExceeded = true;
        break;
      }
    }
    stopwatch.stop();

    if (deadlineExceeded) {
      for (final entry in _registrations.entries.toList(growable: false)) {
        final registration = entry.value;
        if (registration.released || _resourceReports.containsKey(entry.key)) {
          continue;
        }
        if (!registration.cleanupCompleted) {
          _resourceReports[entry.key] = RunCancellationResourceReport(
            label: registration.label,
            outcome: RunCancellationResourceOutcome.timedOut,
            error: registration.cleanupError,
          );
        }
      }
    }

    final hasCleanupFailure = _resourceReports.values.any(
      (report) =>
          report.outcome == RunCancellationResourceOutcome.cleanupFailed,
    );

    return _finalizeReport(
      reason: reason,
      acceptedAt: acceptedAt,
      cleanupDeadlineExceeded: deadlineExceeded,
      finalState: deadlineExceeded || hasCleanupFailure
          ? RunCancellationState.cleanupFailed
          : RunCancellationState.cancelled,
    );
  }

  Future<void> _startRegistrationCleanup(
    String registrationId,
    _ResourceRegistration registration,
  ) {
    final existing = registration.cleanupFuture;
    if (existing != null) {
      return existing;
    }
    if (registration.released) {
      return Future.value();
    }
    final cleanupFuture = _runRegistrationCleanup(registrationId, registration);
    registration.cleanupFuture = cleanupFuture;
    return cleanupFuture;
  }

  Future<void> _runRegistrationCleanup(
    String registrationId,
    _ResourceRegistration registration,
  ) async {
    registration.cleanupStarted = true;
    try {
      await registration.cleanup();
      registration.cleanupCompleted = true;
      if (!registration.released) {
        _resourceReports[registrationId] = RunCancellationResourceReport(
          label: registration.label,
          outcome: RunCancellationResourceOutcome.cancelled,
        );
      }
    } catch (error) {
      registration.cleanupError = error;
      if (!registration.released) {
        _resourceReports[registrationId] = RunCancellationResourceReport(
          label: registration.label,
          outcome: RunCancellationResourceOutcome.cleanupFailed,
          error: error,
        );
      }
    } finally {
      _registrations.remove(registrationId);
    }
  }

  RunCancellationReport _finalizeReport({
    required RunCancellationReason reason,
    required DateTime acceptedAt,
    required bool cleanupDeadlineExceeded,
    required RunCancellationState finalState,
  }) {
    final report = RunCancellationReport(
      reason: reason,
      finalState: finalState,
      acceptedAt: acceptedAt,
      completedAt: DateTime.now(),
      resources: _resourceReports.values.toList(growable: false),
      cleanupDeadlineExceeded: cleanupDeadlineExceeded,
    );
    _report = report;
    _state = finalState;
    _cancelFuture = Future.value(report);
    return report;
  }
}
