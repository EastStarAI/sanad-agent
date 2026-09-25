import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sanad_agent/cli/artifacts/run_artifacts.dart';
import 'package:sanad_agent/cli/oneshot/oneshot_runner.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/cli/workspace/workspace_cli_service.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/interfaces/models/remote_cli.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

import '../sanad_protocol_bridge.dart';

/// Factory signature for constructing [SanadCommandRunner] with injected sinks.
typedef SanadCommandRunnerFactory =
    SanadCommandRunner Function({
      required StringSink stdoutSink,
      required StringSink stderrSink,
      required StdinReader stdinReader,
      WorkspaceCliService? workspaceService,
      Stream<ProcessSignal>? signalStream,
      void Function(RunLifecycleEvent event)? eventSink,
    });

/// Injected [StringSink] forwarding written chunks directly to an asynchronous callback.
class RemoteCliStreamingSink implements StringSink {
  final void Function(String chunk) _onChunk;

  RemoteCliStreamingSink(this._onChunk);

  @override
  void write(Object? obj) {
    final str = obj?.toString() ?? '';
    if (str.isNotEmpty) {
      _onChunk(str);
    }
  }

  @override
  void writeln([Object? obj = '']) {
    final str = '${obj?.toString() ?? ''}\n';
    _onChunk(str);
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) {
    final str = objects.map((e) => e?.toString() ?? '').join(separator);
    if (str.isNotEmpty) {
      _onChunk(str);
    }
  }

  @override
  void writeCharCode(int charCode) {
    _onChunk(String.fromCharCode(charCode));
  }
}

class _ActiveCliExecution {
  final String requestId;
  final String deviceId;
  final StreamController<ProcessSignal> cancelSignalController;
  final Completer<void> cancelCompleter;
  int _seq = 0;
  bool isTerminal = false;
  bool cancelled = false;
  bool timedOut = false;

  _ActiveCliExecution({
    required this.requestId,
    required this.deviceId,
  }) : cancelSignalController = StreamController<ProcessSignal>.broadcast(),
       cancelCompleter = Completer<void>();

  int nextSeq() => ++_seq;
}

/// Owns remote Sanad CLI command execution and streamed event lifecycle.
class RemoteCliCommandHandler {
  final SanadProtocolBridge _bridge;
  final AuthManager _authManager;
  final LocalWorkspaceRuntimeService? _workspaceRuntime;
  final SanadCommandRunnerFactory _runnerFactory;
  final Duration duplicateTtl;
  final DateTime Function() _clock;

  final Map<String, _ActiveCliExecution> _activeExecutions = {};
  final Map<String, DateTime> _completedRequests = {};
  final _logger = Logger('RemoteCliCommandHandler');

  RemoteCliCommandHandler({
    required SanadProtocolBridge bridge,
    required AuthManager authManager,
    LocalWorkspaceRuntimeService? workspaceRuntime,
    SanadCommandRunnerFactory? runnerFactory,
    this.duplicateTtl = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _bridge = bridge,
       _authManager = authManager,
       _workspaceRuntime = workspaceRuntime,
       _clock = clock ?? DateTime.now,
       _runnerFactory =
           runnerFactory ??
           (({
             required stdoutSink,
             required stderrSink,
             required stdinReader,
             workspaceService,
             signalStream,
             eventSink,
           }) => SanadCommandRunner(
             stdoutSink: stdoutSink,
             stderrSink: stderrSink,
             stdinReader: stdinReader,
             workspaceService: workspaceService,
             signalStream: signalStream,
             eventSink: eventSink,
           ));

  void _purgeExpired() {
    final now = _clock();
    _completedRequests.removeWhere((_, time) => now.difference(time) > duplicateTtl);
  }

  /// Handles incoming `device.cli.execute` commands.
  Future<void> handleExecute(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final rawRequestId = event.payload['request_id']?.toString() ?? '';
    final envelopeDeviceId = event.payload['device_id']?.toString() ?? '';

    RemoteCliExecuteRequest request;
    try {
      request = RemoteCliExecuteRequest.fromPayload(
        deviceId: envelopeDeviceId,
        payload: event.payload,
        envelopeRequestId: rawRequestId,
      );
    } on FormatException catch (e) {
      _logger.warning('Invalid remote CLI execute request: ${e.message}');
      await emitEnvelope({
        'type': 'error',
        'request_id': rawRequestId,
        'device_id': envelopeDeviceId,
        'payload': {
          'request_id': rawRequestId,
          'code': RemoteCliErrorCodes.invalidRequest,
          'message': e.message,
        },
      });
      return;
    }

    // Verify target device identity if specified
    final localHardwareId = _authManager.hardwareId;
    if (request.deviceId.isNotEmpty &&
        localHardwareId != null &&
        localHardwareId.isNotEmpty &&
        request.deviceId != localHardwareId) {
      await emitEnvelope({
        'type': 'error',
        'request_id': request.requestId,
        'device_id': request.deviceId,
        'payload': {
          'request_id': request.requestId,
          'code': RemoteCliErrorCodes.wrongDevice,
          'message': 'The command targeted a different device.',
        },
      });
      return;
    }

    _purgeExpired();
    if (_activeExecutions.containsKey(request.requestId) ||
        _completedRequests.containsKey(request.requestId)) {
      _logger.warning('Duplicate remote CLI execute request: ${request.requestId}');
      await emitEnvelope({
        'type': 'error',
        'request_id': request.requestId,
        'device_id': request.deviceId,
        'payload': {
          'request_id': request.requestId,
          'code': RemoteCliErrorCodes.duplicateRequest,
          'message': 'Request ${request.requestId} is already active or recently completed.',
        },
      });
      return;
    }

    // Bounded metadata logging only: payloads, tokens, and prompt text NEVER enter logs
    _logger.info(
      'Admitting remote CLI execute: request_id=${request.requestId}, '
      'arg_count=${request.argv.length}, stdin_bytes=${request.stdin?.length ?? 0}, '
      'timeout_s=${request.timeoutSeconds}',
    );

    final execution = _ActiveCliExecution(
      requestId: request.requestId,
      deviceId: request.deviceId,
    );
    _activeExecutions[request.requestId] = execution;

    Directory? tempBriefDir;
    List<String> effectiveArgv = List.from(request.argv);

    // Materialize brief_content if provided
    if (request.briefFileContent != null && request.briefFileContent!.isNotEmpty) {
      try {
        tempBriefDir = Directory.systemTemp.createTempSync('sanad_remote_brief_');
        final tempBriefFile = File('${tempBriefDir.path}/brief.txt');
        tempBriefFile.writeAsStringSync(request.briefFileContent!);

        // If argv has -b or --brief-file, point it to the remote temporary file
        var replaced = false;
        for (var i = 0; i < effectiveArgv.length; i++) {
          if (effectiveArgv[i] == '-b' || effectiveArgv[i] == '--brief-file') {
            if (i + 1 < effectiveArgv.length) {
              effectiveArgv[i + 1] = tempBriefFile.path;
              replaced = true;
              break;
            }
          } else if (effectiveArgv[i].startsWith('--brief-file=')) {
            effectiveArgv[i] = '--brief-file=${tempBriefFile.path}';
            replaced = true;
            break;
          }
        }
        if (!replaced) {
          effectiveArgv.addAll(['--brief-file', tempBriefFile.path]);
        }
      } catch (e) {
        _logger.warning('Failed to materialize brief content: $e');
        _activeExecutions.remove(request.requestId);
        await emitEnvelope({
          'type': 'error',
          'request_id': request.requestId,
          'device_id': request.deviceId,
          'payload': {
            'request_id': request.requestId,
            'code': RemoteCliErrorCodes.invalidRequest,
            'message': 'Failed to materialize brief file content: $e',
          },
        });
        return;
      }
    }

    final streamingStdoutSink = RemoteCliStreamingSink((chunk) {
      if (execution.isTerminal) return;
      emitEnvelope(_bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.deviceCliStdout,
          payload: {
            'request_id': request.requestId,
            'seq': execution.nextSeq(),
            'stream': 'stdout',
            'text': chunk,
          },
        ),
      )).catchError((_) {
        _handleDisconnect(execution);
      });
    });

    final streamingStderrSink = RemoteCliStreamingSink((chunk) {
      if (execution.isTerminal) return;
      emitEnvelope(_bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.deviceCliStderr,
          payload: {
            'request_id': request.requestId,
            'seq': execution.nextSeq(),
            'stream': 'stderr',
            'text': chunk,
          },
        ),
      )).catchError((_) {
        _handleDisconnect(execution);
      });
    });

    void onLifecycleEvent(RunLifecycleEvent lcEvent) {
      if (execution.isTerminal) return;
      emitEnvelope(_bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.deviceCliEvent,
          payload: {
            'request_id': request.requestId,
            'seq': execution.nextSeq(),
            'event': lcEvent.toJson(),
          },
        ),
      )).catchError((_) {
        _handleDisconnect(execution);
      });
    }

    WorkspaceCliService? workspaceService;
    if (_workspaceRuntime != null) {
      workspaceService = WorkspaceCliService(
        runtimeService: _workspaceRuntime,
      );
    }

    final runner = _runnerFactory(
      stdoutSink: streamingStdoutSink,
      stderrSink: streamingStderrSink,
      stdinReader: () async => request.stdin,
      workspaceService: workspaceService,
      signalStream: execution.cancelSignalController.stream,
      eventSink: onLifecycleEvent,
    );

    final stopwatch = Stopwatch()..start();
    final timeoutDuration = Duration(seconds: request.timeoutSeconds);

    Timer? timeoutTimer;
    timeoutTimer = Timer(timeoutDuration, () {
      if (!execution.cancelCompleter.isCompleted) {
        execution.timedOut = true;
        execution.cancelSignalController.add(ProcessSignal.sigint);
        execution.cancelCompleter.complete();
      }
    });

    try {
      final runFuture = runner.run(effectiveArgv);
      final exitCode = await Future.any([
        runFuture,
        execution.cancelCompleter.future.then((_) => execution.timedOut ? 124 : 130),
      ]);
      stopwatch.stop();
      timeoutTimer.cancel();

      await _emitTerminalResult(
        emitEnvelope: emitEnvelope,
        execution: execution,
        exitCode: exitCode,
        durationMs: stopwatch.elapsedMilliseconds,
        cancelled: execution.cancelled,
        timedOut: execution.timedOut,
      );
    } catch (error) {
      stopwatch.stop();
      timeoutTimer.cancel();
      await _emitTerminalResult(
        emitEnvelope: emitEnvelope,
        execution: execution,
        exitCode: 1,
        durationMs: stopwatch.elapsedMilliseconds,
        cancelled: execution.cancelled,
        timedOut: execution.timedOut,
        error: error.toString(),
      );
    } finally {
      _activeExecutions.remove(request.requestId);
      _completedRequests[request.requestId] = _clock();
      await execution.cancelSignalController.close();
      if (tempBriefDir != null && tempBriefDir.existsSync()) {
        try {
          tempBriefDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Handles incoming `device.cli.cancel` commands.
  Future<void> handleCancel(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final rawRequestId = event.payload['request_id']?.toString() ?? '';
    final envelopeDeviceId = event.payload['device_id']?.toString() ?? '';

    RemoteCliCancelRequest request;
    try {
      request = RemoteCliCancelRequest.fromPayload(
        deviceId: envelopeDeviceId,
        payload: event.payload,
        envelopeRequestId: rawRequestId,
      );
    } on FormatException catch (e) {
      _logger.warning('Invalid remote CLI cancel request: ${e.message}');
      await emitEnvelope({
        'type': 'error',
        'request_id': rawRequestId,
        'device_id': envelopeDeviceId,
        'payload': {
          'request_id': rawRequestId,
          'code': RemoteCliErrorCodes.invalidRequest,
          'message': e.message,
        },
      });
      return;
    }

    final active = _activeExecutions[request.targetRequestId];
    if (active == null) {
      _logger.info('Remote CLI cancel target not found: ${request.targetRequestId}');
      await emitEnvelope({
        'type': 'error',
        'request_id': request.requestId,
        'device_id': request.deviceId,
        'payload': {
          'request_id': request.requestId,
          'target_request_id': request.targetRequestId,
          'code': RemoteCliErrorCodes.notFound,
          'message': 'No active remote CLI execution found for target_request_id: ${request.targetRequestId}',
        },
      });
      return;
    }

    _logger.info('Remote CLI cancelling request: ${request.targetRequestId}');
    active.cancelled = true;
    active.cancelSignalController.add(ProcessSignal.sigint);
    if (!active.cancelCompleter.isCompleted) {
      active.cancelCompleter.complete();
    }

    await emitEnvelope(_bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.deviceCliCancel,
        payload: {
          'request_id': request.requestId,
          'target_request_id': request.targetRequestId,
          'success': true,
        },
      ),
    ));
  }

  void _handleDisconnect(_ActiveCliExecution execution) {
    if (execution.isTerminal) return;
    _logger.info('Remote CLI caller disconnected: request_id=${execution.requestId}');
    execution.cancelled = true;
    execution.cancelSignalController.add(ProcessSignal.sigint);
    if (!execution.cancelCompleter.isCompleted) {
      execution.cancelCompleter.complete();
    }
  }

  Future<void> _emitTerminalResult({
    required Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
    required _ActiveCliExecution execution,
    required int exitCode,
    required int durationMs,
    bool cancelled = false,
    bool timedOut = false,
    String? error,
  }) async {
    if (execution.isTerminal) return;
    execution.isTerminal = true;

    _logger.info(
      'Remote CLI execution completed: request_id=${execution.requestId}, '
      'exit_code=$exitCode, duration_ms=$durationMs, '
      'cancelled=$cancelled, timed_out=$timedOut',
    );

    final result = RemoteCliResult(
      requestId: execution.requestId,
      seq: execution.nextSeq(),
      exitCode: exitCode,
      durationMs: durationMs,
      cancelled: cancelled,
      timedOut: timedOut,
      error: error,
    );

    try {
      await emitEnvelope(_bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.deviceCliResult,
          payload: result.toPayload(),
        ),
      ));
    } catch (e) {
      _logger.warning('Failed to emit remote CLI terminal result: $e');
    }
  }
}
