import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../core/sanad_home/runtime_ownership.dart';
import '../../interfaces/models/agent_turn_request.dart';
import '../client/cli_turn_client.dart';
import '../client/local_gateway_cli_client.dart';
import '../client/standalone_cli_turn_client.dart';
import '../discovery/local_gateway_discovery.dart';
import '../fallback/standalone_fallback_strategy.dart';
import '../models/cli_events.dart';
import '../models/model_provider_resolver.dart';
import '../ui/cli_tool_formatter.dart';
import '../workspace/cli_workspace_state.dart';
import '../workspace/workspace_locator.dart';

/// Signature for reading piped input from standard input.
typedef StdinReader = Future<String?> Function();

/// Signature for constructing a [LocalGatewayCliClient].
typedef ClientFactory =
    Future<LocalGatewayCliClient> Function({
      String? urlOverride,
      String? sanadHomeOverride,
    });

typedef StandaloneClientFactory =
    Future<CliTurnClient> Function({String? sanadHomeOverride});

/// Default reader that checks whether stdin is a pipe or redirected file,
/// and reads all bytes until EOF.
Future<String?> defaultStdinReader() async {
  try {
    if (stdin.hasTerminal) {
      return null;
    }
    final buffer = StringBuffer();
    final completer = Completer<String?>();

    final sub = stdin
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          buffer.write,
          onError: (_) {
            if (!completer.isCompleted) completer.complete(null);
          },
          onDone: () {
            if (!completer.isCompleted) {
              final content = buffer.toString().trim();
              completer.complete(content.isNotEmpty ? content : null);
            }
          },
          cancelOnError: true,
        );

    return await completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        sub.cancel();
        final content = buffer.toString().trim();
        return content.isNotEmpty ? content : null;
      },
    );
  } catch (_) {
    return null;
  }
}

/// Represents the structured outcome of a one-shot execution turn.
class OneshotResult {
  final int exitCode;
  final String text;
  final List<Map<String, dynamic>> toolExecutions;
  final Map<String, dynamic>? usage;
  final String? model;
  final String? provider;
  final String sessionId;
  final String? error;

  const OneshotResult({
    required this.exitCode,
    required this.text,
    this.toolExecutions = const [],
    this.usage,
    this.model,
    this.provider,
    required this.sessionId,
    this.error,
  });

  bool get isSuccess => exitCode == 0;

  Map<String, dynamic> toJson() => {
    'session_id': sessionId,
    'text': text,
    'tool_executions': toolExecutions,
    'exit_code': exitCode,
    if (usage != null) 'usage': usage,
    if (model != null) 'model': model,
    if (provider != null) 'provider': provider,
    if (error != null) 'error': error,
  };
}

/// Headless runner that executes one-shot reasoning turns and Unix pipe workflows.
class OneshotRunner {
  final _logger = Logger('OneshotRunner');
  final _uuid = const Uuid();

  final StdinReader stdinReader;
  final ClientFactory? clientFactory;
  final StandaloneClientFactory standaloneClientFactory;
  final StandaloneFallbackStrategy fallbackStrategy;

  OneshotRunner({
    StdinReader? stdinReader,
    this.clientFactory,
    StandaloneClientFactory? standaloneClientFactory,
    StandaloneFallbackStrategy? fallbackStrategy,
  }) : stdinReader = stdinReader ?? defaultStdinReader,
       standaloneClientFactory =
           standaloneClientFactory ?? StandaloneCliTurnClient.start,
       fallbackStrategy = fallbackStrategy ?? StandaloneFallbackStrategy();

  /// Executes a single one-shot agent turn, formats the output according to flags,
  /// and returns the process exit code (0 for success, 1 for failure).
  Future<int> run({
    String? prompt,
    String? workspace,
    String? session,
    String? model,
    String? provider,
    bool thinking = false,
    bool quiet = false,
    bool json = false,
    bool standalone = false,
    String? gatewayUrl,
    String? sanadHome,
    bool allowAllTools = false,
    StringSink? stdoutSink,
    StringSink? stderrSink,
    CliTurnClient? client,
    Duration timeout = const Duration(minutes: 5),
    Stream<ProcessSignal>? signalStream,
  }) async {
    final out = stdoutSink ?? stdout;
    final err = stderrSink ?? stderr;

    void emitJsonResult(OneshotResult result) {
      if (json) out.writeln(jsonEncode(result.toJson()));
    }

    // 1. Resolve prompt and piped input from stdin
    String? pipedContent;
    try {
      pipedContent = await stdinReader();
    } catch (e) {
      _logger.warning('Failed to read piped stdin: $e');
    }

    final trimmedPrompt = prompt?.trim() ?? '';
    final trimmedPiped = pipedContent?.trim() ?? '';

    final String effectivePrompt;
    if (trimmedPrompt.isNotEmpty && trimmedPiped.isNotEmpty) {
      effectivePrompt = '$trimmedPrompt\n\n$trimmedPiped';
    } else if (trimmedPrompt.isNotEmpty) {
      effectivePrompt = trimmedPrompt;
    } else if (trimmedPiped.isNotEmpty) {
      effectivePrompt = trimmedPiped;
    } else {
      err.writeln('Error: No prompt or instruction provided.');
      err.writeln(
        'Usage: sanad run "<prompt>" or cat file | sanad run "prompt"',
      );
      emitJsonResult(
        const OneshotResult(
          exitCode: 1,
          text: '',
          sessionId: '',
          error: 'No prompt or instruction provided.',
        ),
      );
      return 1;
    }

    final effectiveSessionId = (session != null && session.trim().isNotEmpty)
        ? session.trim()
        : 'oneshot-${_uuid.v4()}';

    // 2. Resolve client connection or standalone fallback
    CliTurnClient? activeClient = client;
    bool shouldDisposeClient = false;

    if (activeClient == null) {
      final effectiveFallback = StandaloneFallbackStrategy(
        discovery: LocalGatewayDiscovery(sanadHomeOverride: sanadHome),
      );
      final mode = await effectiveFallback.resolveMode(
        forceStandalone: standalone,
        urlOverride: gatewayUrl,
      );

      if (mode == CliRuntimeMode.standalone) {
        if (standalone) {
          try {
            final owner =
                await LocalGatewayDiscovery(
                  sanadHomeOverride: sanadHome,
                ).discover(
                  urlOverride: gatewayUrl,
                  probeTimeout: const Duration(milliseconds: 300),
                );
            if (owner.isDaemonRunning) {
              err.writeln(
                'Error: --standalone cannot use this Sanad Home while its daemon is active.',
              );
              const message =
                  '--standalone cannot use this Sanad Home while its daemon is active.';
              err.writeln(
                'Hint: omit --standalone to attach to the running daemon.',
              );
              emitJsonResult(
                OneshotResult(
                  exitCode: 78,
                  text: '',
                  sessionId: effectiveSessionId,
                  error: message,
                ),
              );
              return 78;
            }
          } on GatewayDiscoveryException {
            // No healthy daemon owns this Home; standalone startup may proceed.
          }
        }
        try {
          activeClient = await standaloneClientFactory(
            sanadHomeOverride: sanadHome,
          );
          shouldDisposeClient = true;
        } on SanadRuntimeOwnershipConflict {
          err.writeln(
            'Error: --standalone cannot use this Sanad Home while another runtime owns it.',
          );
          err.writeln(
            'Hint: omit --standalone to attach to the running daemon.',
          );
          emitJsonResult(
            OneshotResult(
              exitCode: 78,
              text: '',
              sessionId: effectiveSessionId,
              error:
                  '--standalone cannot use this Sanad Home while another runtime owns it.',
            ),
          );
          return 78;
        } catch (e) {
          err.writeln('Error: Failed to start standalone runtime: $e');
          if (json) {
            final res = OneshotResult(
              exitCode: 1,
              text: '',
              sessionId: effectiveSessionId,
              error: 'Failed to start standalone runtime: $e',
            );
            emitJsonResult(res);
          }
          return 1;
        }
      } else {
        try {
          if (clientFactory != null) {
            activeClient = await clientFactory!(
              urlOverride: gatewayUrl,
              sanadHomeOverride: sanadHome,
            );
          } else {
            activeClient = await LocalGatewayCliClient.discoverAndConnect(
              urlOverride: gatewayUrl,
              sanadHomeOverride: sanadHome,
            );
          }
          shouldDisposeClient = true;
        } catch (e) {
          err.writeln('Error: Failed to connect to Sanad daemon: $e');
          if (json) {
            final res = OneshotResult(
              exitCode: 1,
              text: '',
              sessionId: effectiveSessionId,
              error: 'Failed to connect to Sanad daemon: $e',
            );
            emitJsonResult(res);
          }
          return 1;
        }
      }
    }

    // 3. Track events and stream output
    final assistantBuffer = StringBuffer();
    final toolExecutions = <Map<String, dynamic>>[];
    final completer = Completer<int>();
    Map<String, dynamic>? usageInfo;
    String? finalModel = model;
    String? finalProvider = provider;
    String? errorMessage;
    bool hasError = false;

    final automaticallyApproveTools = allowAllTools;

    final subscriptions = <StreamSubscription<dynamic>>[];
    var stopRequested = false;

    Future<void> requestStop() async {
      if (stopRequested) return;
      stopRequested = true;
      try {
        await activeClient!
            .stop(sessionId: effectiveSessionId)
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        // Cleanup below still disposes the transport and in-process runtime.
      }
    }

    void cleanup() {
      for (final s in subscriptions) {
        s.cancel();
      }
      subscriptions.clear();
    }

    try {
      Future<void> handleSignal(ProcessSignal signal) async {
        if (completer.isCompleted) return;
        final signalCode = signal == ProcessSignal.sigterm ? 143 : 130;
        hasError = true;
        errorMessage = signal == ProcessSignal.sigterm
            ? 'Turn execution terminated by SIGTERM.'
            : 'Turn execution interrupted by SIGINT.';
        await requestStop();
        if (!json) err.writeln('Error: $errorMessage');
        if (!completer.isCompleted) completer.complete(signalCode);
      }

      if (signalStream != null) {
        subscriptions.add(signalStream.listen(handleSignal));
      } else {
        for (final signal in <ProcessSignal>[
          ProcessSignal.sigint,
          ProcessSignal.sigterm,
        ]) {
          try {
            subscriptions.add(signal.watch().listen(handleSignal));
          } on UnsupportedError {
            // The platform does not expose this process signal.
          }
        }
      }

      subscriptions.add(
        activeClient.assistantStream.listen((event) {
          if (event.sessionId == null ||
              event.sessionId == effectiveSessionId) {
            assistantBuffer.write(event.content);
            if (!json && !quiet) {
              out.write(event.content);
            }
          }
        }),
      );

      subscriptions.add(
        activeClient.reasoningStream.listen((event) {
          if (event.sessionId == null ||
              event.sessionId == effectiveSessionId) {
            if (thinking && !json && !quiet) {
              out.write(event.content);
            }
          }
        }),
      );

      subscriptions.add(
        activeClient.toolCallStream.listen((event) {
          if (event.sessionId == null ||
              event.sessionId == effectiveSessionId) {
            toolExecutions.add({
              'tool_name': event.toolName,
              'tool_call_id': event.toolCallId,
              'arguments': event.arguments,
            });
            if (!json && !quiet) {
              final callingStr = CliToolFormatter.formatToolCalling(
                event.toolName,
                event.arguments,
              );
              out.writeln('\n$callingStr');
            }
          }
        }),
      );

      subscriptions.add(
        activeClient.toolResultStream.listen((event) {
          if (event.sessionId == null ||
              event.sessionId == effectiveSessionId) {
            final match = toolExecutions.lastWhere(
              (t) =>
                  t['tool_call_id'] == event.toolCallId ||
                  (t['tool_name'] == event.toolName &&
                      !t.containsKey('result')),
              orElse: () {
                final entry = <String, dynamic>{
                  'tool_name': event.toolName,
                  'tool_call_id': event.toolCallId,
                };
                toolExecutions.add(entry);
                return entry;
              },
            );
            match['result'] = event.result;
            match['is_error'] = event.isError;

            if (!json && !quiet) {
              final effectiveName = event.toolName.isNotEmpty
                  ? event.toolName
                  : (match['tool_name']?.toString() ?? 'tool');
              final rawArgs = match['arguments'];
              final argsMap = rawArgs is Map<String, dynamic>
                  ? rawArgs
                  : rawArgs is Map
                  ? Map<String, dynamic>.from(rawArgs)
                  : null;
              final resultStr = CliToolFormatter.formatToolResult(
                toolName: effectiveName,
                result: event.result,
                isError: event.isError,
                arguments: argsMap,
              );
              out.writeln(resultStr);
            }
          }
        }),
      );

      subscriptions.add(
        activeClient.permissionStream.listen((event) async {
          if (event.sessionId == null ||
              event.sessionId == effectiveSessionId) {
            if (!automaticallyApproveTools) {
              if (!json && !quiet) {
                err.writeln(
                  'Notice: Gated tool "${event.toolName}" was rejected in non-interactive execution.',
                );
              }
            }
            try {
              await activeClient!.respondPermission(
                requestId: event.requestId,
                allowed: automaticallyApproveTools,
                decision: automaticallyApproveTools ? 'allow' : 'deny',
              );
            } catch (e) {
              _logger.warning('Failed to respond to permission request: $e');
            }
          }
        }),
      );

      subscriptions.add(
        activeClient.turnCompleteStream.listen((event) {
          if (event.sessionId == null ||
              event.sessionId == effectiveSessionId) {
            usageInfo = event.usage ?? event.contextUsage;
            if (event.model != null) finalModel = event.model;
            if (event.provider != null) finalProvider = event.provider;

            if (assistantBuffer.isEmpty && event.finalMessage.isNotEmpty) {
              assistantBuffer.write(event.finalMessage);
              if (!json && !quiet) {
                out.write(event.finalMessage);
              }
            }

            if (!completer.isCompleted) {
              completer.complete(0);
            }
          }
        }),
      );

      subscriptions.add(
        activeClient.eventStream
            .where((e) => e is CliErrorEvent)
            .cast<CliErrorEvent>()
            .listen((event) {
              if (event.sessionId == null ||
                  event.sessionId == effectiveSessionId) {
                hasError = true;
                errorMessage = event.message;
                if (!json) {
                  err.writeln('Error: ${event.message}');
                }
                if (!completer.isCompleted) {
                  completer.complete(1);
                }
              }
            }),
      );

      subscriptions.add(
        activeClient.eventStream
            .where((e) => e is CliRuntimeNoticeEvent)
            .cast<CliRuntimeNoticeEvent>()
            .listen((event) {
              if (event.sessionId == null ||
                  event.sessionId == effectiveSessionId) {
                hasError = true;
                errorMessage = event.message;
                if (!json) {
                  err.writeln('Error: ${event.message}');
                }
                if (!completer.isCompleted) {
                  completer.complete(1);
                }
              }
            }),
      );

      subscriptions.add(
        activeClient.stateStream.listen((state) {
          if (state == CliConnectionState.closed ||
              state == CliConnectionState.disconnected) {
            if (!completer.isCompleted) {
              hasError = true;
              errorMessage = 'Gateway connection lost before turn completed.';
              if (!json) {
                err.writeln('Error: $errorMessage');
              }
              completer.complete(1);
            }
          }
        }),
      );

      // 4. Resolve Model and Provider via ModelProviderResolver
      final resolver = ModelProviderResolver(
        sanadHomeOverride: sanadHome,
        allowFallback:
            client != null ||
            Platform.environment['SANAD_E2E_TEST_MODE'] == 'true',
      );
      final resolution = resolver.resolve(
        requestedModel: model,
        requestedProvider: provider,
      );

      if (!resolution.isSuccess) {
        err.writeln('Error: ${resolution.errorMessage}');
        if (resolution.hintMessage != null) {
          err.writeln('Hint: ${resolution.hintMessage}');
        }
        if (json) {
          final res = OneshotResult(
            exitCode: 1,
            text: '',
            sessionId: effectiveSessionId,
            error:
                '${resolution.errorMessage}\n${resolution.hintMessage ?? ''}',
          );
          emitJsonResult(res);
        }
        return 1;
      }

      final resolvedModel = resolution.resolved!.modelName;
      final resolvedProviderId = resolution.resolved!.providerId;

      String? resolvedWorkspaceId;
      if (workspace != null && workspace.trim().isNotEmpty) {
        final requestedWorkspace = workspace.trim();
        if (activeClient is LocalGatewayCliClient) {
          final locator = WorkspaceLocator(
            gatewayClient: activeClient,
            stateStore: CliWorkspaceStateStore(sanadHomeOverride: sanadHome),
          );
          try {
            final matchedWs = await locator.resolveActiveWorkspace(
              explicitIdOrPath: requestedWorkspace,
            );
            resolvedWorkspaceId =
                matchedWs?['id']?.toString() ?? requestedWorkspace;
          } catch (e) {
            _logger.warning('Failed to resolve workspace: $e');
            resolvedWorkspaceId = requestedWorkspace;
          }
        } else {
          resolvedWorkspaceId = requestedWorkspace;
        }
      }

      final turnRequest = AgentTurnRequest(
        sessionId: effectiveSessionId,
        message: effectivePrompt,
        workspaceId: resolvedWorkspaceId,
        model: resolvedModel,
        providerInstanceId: resolvedProviderId,
        providerId: resolvedProviderId,
        thinkingMode: thinking ? 'deep' : null,
      );

      if (!json && !quiet) {
        out.writeln(
          'Sanad Agent — Executing turn for session: $effectiveSessionId',
        );
      }

      await activeClient.dispatchTurnRequest(turnRequest);

      // 5. Await turn completion or timeout
      int exitStatus;
      try {
        exitStatus = await completer.future.timeout(timeout);
      } on TimeoutException {
        hasError = true;
        errorMessage = 'Turn execution timed out after ${timeout.inSeconds}s';
        await requestStop();
        if (!json) {
          err.writeln('Error: $errorMessage');
        }
        exitStatus = 124;
      }

      // 6. Handle final output presentation
      if (json) {
        final result = OneshotResult(
          exitCode: exitStatus,
          text: assistantBuffer.toString(),
          toolExecutions: toolExecutions,
          usage: usageInfo,
          model: finalModel,
          provider: finalProvider,
          sessionId: effectiveSessionId,
          error: hasError ? errorMessage : null,
        );
        emitJsonResult(result);
      } else if (quiet) {
        final text = assistantBuffer.toString();
        out.writeln(text.trimRight());
      } else {
        if (assistantBuffer.isNotEmpty) {
          final text = assistantBuffer.toString();
          if (!text.endsWith('\n')) {
            out.writeln();
          }
        }
      }

      return exitStatus;
    } finally {
      cleanup();
      if (shouldDisposeClient) {
        try {
          await activeClient.dispose().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    }
  }
}
