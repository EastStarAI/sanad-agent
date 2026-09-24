import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../interfaces/models/agent_turn_request.dart';
import '../client/local_gateway_cli_client.dart';
import '../models/cli_events.dart';
import '../models/model_provider_resolver.dart';
import '../oneshot/oneshot_runner.dart';
import '../ui/cli_tool_formatter.dart';
import '../ui/terminal_renderer.dart';
import '../workspace/cli_workspace_state.dart';
import '../workspace/workspace_locator.dart';
import 'interactive_ask_user.dart';
import 'interactive_permission.dart';
import 'repl_history.dart';
import 'repl_line_reader.dart';
import 'repl_prompt.dart';
import 'slash_command_handler.dart';

/// Manages a rich interactive REPL session with the Sanad Local Gateway.
///
/// Features:
/// - Command history with navigation (up/down arrows) persisted to `SANAD_HOME/cli_history`.
/// - Dynamic prompt display showing active workspace and model.
/// - Interactive question handling for `system_ask_user`.
/// - Interactive tool permissions with scope (`Once`, `Session`, `Workspace`).
/// - Keypress/signal handling: Ctrl+C stops active turns, Ctrl+D/exit exits cleanly.
class InteractiveReplSession {
  final _logger = Logger('InteractiveReplSession');
  final _uuid = const Uuid();

  final LocalGatewayCliClient? clientOverride;
  final ClientFactory? clientFactory;
  final String? initialWorkspace;
  final String? initialSession;
  final String? initialModel;
  final String? initialProvider;
  bool thinking;
  final bool standalone;
  final String? gatewayUrl;
  final String? sanadHome;
  final ReplLineReader? lineReaderOverride;
  final ReplHistory? historyOverride;
  final StringSink stdoutSink;
  final StringSink stderrSink;
  final WorkspaceLocator? workspaceLocator;
  final bool enableAnsi;

  InteractiveReplSession({
    this.clientOverride,
    this.clientFactory,
    String? workspace,
    String? session,
    String? model,
    String? provider,
    this.thinking = false,
    this.standalone = false,
    this.gatewayUrl,
    this.sanadHome,
    this.lineReaderOverride,
    this.historyOverride,
    StringSink? stdoutSink,
    StringSink? stderrSink,
    this.workspaceLocator,
    bool? enableAnsi,
  }) : initialWorkspace = workspace,
       initialSession = session,
       initialModel = model,
       initialProvider = provider,
       stdoutSink = stdoutSink ?? stdout,
       stderrSink = stderrSink ?? stderr,
       enableAnsi =
           enableAnsi ??
           ((stdoutSink == null || identical(stdoutSink, stdout)) &&
               stdout.hasTerminal);

  /// Executes the interactive REPL session loop until user exits.
  Future<int> run() async {
    final history =
        historyOverride ?? ReplHistory(sanadHomeOverride: sanadHome);
    await history.load();

    final lineReader =
        lineReaderOverride ??
        TerminalReplLineReader(
          output: stdoutSink,
          history: history,
          enableAnsi: enableAnsi,
        );

    // 1. Resolve Gateway Client
    LocalGatewayCliClient? activeClient = clientOverride;
    bool shouldDisposeClient = false;

    if (activeClient == null) {
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
        stderrSink.writeln('Error: Failed to connect to Sanad daemon: $e');
        stderrSink.writeln(
          'Hint: Start the daemon with "sanad daemon" or check daemon status.',
        );
        return 1;
      }
    }

    // 2. Resolve Active Workspace and Session
    final locator =
        workspaceLocator ??
        WorkspaceLocator(
          gatewayClient: activeClient,
          stateStore: CliWorkspaceStateStore(sanadHomeOverride: sanadHome),
        );

    String? currentWorkspaceName;
    String? currentWorkspaceId;

    try {
      final matchedWs = await locator.resolveActiveWorkspace(
        explicitIdOrPath: initialWorkspace,
      );
      if (matchedWs != null) {
        currentWorkspaceId = matchedWs['id']?.toString();
        currentWorkspaceName =
            matchedWs['name']?.toString() ??
            matchedWs['display_name']?.toString();
      }
    } catch (_) {}

    currentWorkspaceName ??= initialWorkspace ?? 'default';

    String effectiveSessionId =
        (initialSession != null && initialSession!.trim().isNotEmpty)
        ? initialSession!.trim()
        : 'session-${_uuid.v4()}';

    String currentModel = initialModel ?? 'default';

    // 3. Print Banner
    stdoutSink.writeln(ReplPrompt.banner(ansi: enableAnsi));
    stdoutSink.writeln();

    // 4. Setup Turn State & Subscriptions
    final subscriptions = <StreamSubscription>[];
    Completer<int>? activeTurnCompleter;
    bool isTurnRunning = false;
    final lastChunkEndedWithNewline = [true];

    final activeToolCalls =
        <
          String,
          ({
            String toolName,
            Map<String, dynamic> arguments,
            DateTime startTime,
          })
        >{};

    void interruptActiveTurn() {
      if (isTurnRunning && activeClient != null) {
        stdoutSink.writeln('\n^C [Turn interrupted]');
        try {
          activeClient.stop(sessionId: effectiveSessionId);
        } catch (_) {}
        if (activeTurnCompleter != null && !activeTurnCompleter.isCompleted) {
          activeTurnCompleter.complete(130);
        }
      }
    }

    // Process Signal Handling (Ctrl+C during turn execution)
    StreamSubscription? sigintSub;
    if (!Platform.isWindows) {
      try {
        sigintSub = ProcessSignal.sigint.watch().listen((_) {
          if (isTurnRunning) {
            interruptActiveTurn();
          } else {
            stdoutSink.writeln('\n(Press Ctrl+D or type "exit" to quit)');
          }
        });
      } catch (_) {}
    }

    subscriptions.add(
      activeClient.assistantStream.listen((event) {
        if (event.sessionId == null || event.sessionId == effectiveSessionId) {
          stdoutSink.write(event.content);
          lastChunkEndedWithNewline[0] = event.content.endsWith('\n');
        }
      }),
    );

    subscriptions.add(
      activeClient.reasoningStream.listen((event) {
        if (event.sessionId == null || event.sessionId == effectiveSessionId) {
          if (thinking) {
            if (enableAnsi) {
              stdoutSink.write('\x1b[90m${event.content}\x1b[0m');
            } else {
              stdoutSink.write(event.content);
            }
            lastChunkEndedWithNewline[0] = event.content.endsWith('\n');
          }
        }
      }),
    );

    subscriptions.add(
      activeClient.toolCallStream.listen((event) {
        if (event.sessionId == null || event.sessionId == effectiveSessionId) {
          activeToolCalls[event.toolCallId] = (
            toolName: event.toolName,
            arguments: event.arguments,
            startTime: DateTime.now(),
          );
          final callingStr = CliToolFormatter.formatToolCalling(
            event.toolName,
            event.arguments,
            ansi: enableAnsi,
          );
          stdoutSink.writeln('\n$callingStr');
          lastChunkEndedWithNewline[0] = true;
        }
      }),
    );

    subscriptions.add(
      activeClient.toolResultStream.listen((event) {
        if (event.sessionId == null || event.sessionId == effectiveSessionId) {
          var callInfo = activeToolCalls.remove(event.toolCallId);
          if (callInfo == null && activeToolCalls.isNotEmpty) {
            final key = activeToolCalls.keys.lastWhere(
              (k) => activeToolCalls[k]?.toolName == event.toolName,
              orElse: () => activeToolCalls.keys.last,
            );
            callInfo = activeToolCalls.remove(key);
          }
          final duration = callInfo != null
              ? DateTime.now().difference(callInfo.startTime)
              : null;
          final effectiveToolName = event.toolName.isNotEmpty
              ? event.toolName
              : (callInfo?.toolName ?? 'tool');
          final resultStr = CliToolFormatter.formatToolResult(
            toolName: effectiveToolName,
            result: event.result,
            isError: event.isError,
            arguments: callInfo?.arguments,
            duration: duration,
            ansi: enableAnsi,
          );
          stdoutSink.writeln(resultStr);
          lastChunkEndedWithNewline[0] = true;
        }
      }),
    );

    subscriptions.add(
      activeClient.permissionStream.listen((event) async {
        if (event.sessionId == null || event.sessionId == effectiveSessionId) {
          if (event.isUserQuestion) {
            final answer = await InteractiveAskUserHandler.prompt(
              event: event,
              lineReader: lineReader,
              output: stdoutSink,
              ansi: enableAnsi,
            );
            try {
              await activeClient!.respondPermission(
                requestId: event.requestId,
                allowed: true,
                answer: answer,
                decision: 'allow',
                sessionId: effectiveSessionId,
              );
              stdoutSink.writeln(
                enableAnsi
                    ? '\x1b[32m✓ Response submitted.\x1b[0m'
                    : '✓ Response submitted.',
              );
            } catch (e) {
              _logger.warning('Failed to respond to user question: $e');
            }
          } else {
            final perm = await InteractivePermissionHandler.prompt(
              event: event,
              lineReader: lineReader,
              output: stdoutSink,
              ansi: enableAnsi,
            );
            try {
              await activeClient!.respondPermission(
                requestId: event.requestId,
                allowed: perm.allowed,
                scope: perm.scope,
                decision: perm.decision,
                comment: perm.comment,
                sessionId: effectiveSessionId,
              );
              final statusColor = perm.allowed ? '\x1b[32m' : '\x1b[31m';
              stdoutSink.writeln(
                enableAnsi
                    ? '$statusColor✓ Decision: ${perm.decision} (${perm.scope})\x1b[0m'
                    : '✓ Decision: ${perm.decision} (${perm.scope})',
              );
            } catch (e) {
              _logger.warning('Failed to respond to permission request: $e');
            }
          }
        }
      }),
    );

    subscriptions.add(
      activeClient.turnCompleteStream.listen((event) {
        if (event.sessionId == null || event.sessionId == effectiveSessionId) {
          if (event.model != null && event.model!.isNotEmpty) {
            currentModel = event.model!;
          }
          if (activeTurnCompleter != null && !activeTurnCompleter.isCompleted) {
            activeTurnCompleter.complete(0);
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
              stderrSink.writeln('\nError: ${event.message}');
              if (activeTurnCompleter != null &&
                  !activeTurnCompleter.isCompleted) {
                activeTurnCompleter.complete(1);
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
              stderrSink.writeln('\nError: ${event.message}');
              if (activeTurnCompleter != null &&
                  !activeTurnCompleter.isCompleted) {
                activeTurnCompleter.complete(1);
              }
            }
          }),
    );

    // 5. Setup Terminal Renderer and Slash Command Handler
    final renderer = TerminalRenderer(
      stdoutSink: stdoutSink,
      stderrSink: stderrSink,
      enableColor: enableAnsi,
      isTerminal: enableAnsi,
    );

    String? currentProvider = initialProvider;

    final slashContext = SlashCommandContext(
      sessionId: effectiveSessionId,
      currentModel: currentModel,
      currentProviderId: currentProvider,
      currentWorkspaceId: currentWorkspaceId,
      currentWorkspaceName: currentWorkspaceName,
      thinking: thinking,
      client: activeClient,
      renderer: renderer,
      locator: locator,
      history: history,
      allowModelFallback: clientOverride != null,
      onStopRequested: () {
        interruptActiveTurn();
      },
    );

    final slashHandler = CliSlashCommandHandler(context: slashContext);

    // 6. Main REPL Input Loop
    try {
      while (true) {
        // Flush any stray keystrokes from turn execution or startup before waiting for input
        lineReader.flush();

        final promptStr = ReplPrompt.format(
          workspace: currentWorkspaceName,
          model: currentModel,
          ansi: enableAnsi,
        );

        final rawInput = await lineReader.readLine(prompt: promptStr);

        // Ctrl+D or EOF
        if (rawInput == null) {
          stdoutSink.writeln('Goodbye!');
          break;
        }

        final trimmed = rawInput.trim();
        if (trimmed.isEmpty) {
          continue;
        }

        // Save command to history
        history.add(rawInput);
        await history.save();

        // Intercept slash commands & exit keywords
        if (CliSlashCommandHandler.isSlashCommand(rawInput)) {
          slashContext.sessionId = effectiveSessionId;
          slashContext.currentModel = currentModel;
          slashContext.currentProviderId = currentProvider;
          slashContext.currentWorkspaceId = currentWorkspaceId;
          slashContext.currentWorkspaceName = currentWorkspaceName;
          slashContext.thinking = thinking;
          slashContext.isTurnRunning = isTurnRunning;

          final slashResult = await slashHandler.handle(rawInput);

          // Synchronize state back
          effectiveSessionId = slashContext.sessionId;
          currentModel = slashContext.currentModel;
          currentProvider = slashContext.currentProviderId;
          currentWorkspaceId = slashContext.currentWorkspaceId;
          currentWorkspaceName = slashContext.currentWorkspaceName;
          thinking = slashContext.thinking;

          if (slashResult.shouldExit) {
            break;
          }
          continue;
        }

        // 7. Dispatch Turn Request
        isTurnRunning = true;
        slashContext.isTurnRunning = true;
        activeTurnCompleter = Completer<int>();

        final resolver = ModelProviderResolver(
          sanadHomeOverride: sanadHome,
          allowFallback: clientOverride != null,
        );
        final resolution = resolver.resolve(
          requestedModel: currentModel != 'default' ? currentModel : null,
          requestedProvider: currentProvider,
        );

        if (!resolution.isSuccess) {
          stderrSink.writeln('Error: ${resolution.errorMessage}');
          if (resolution.hintMessage != null) {
            stderrSink.writeln('Hint: ${resolution.hintMessage}');
          }
          isTurnRunning = false;
          slashContext.isTurnRunning = false;
          activeTurnCompleter = null;
          continue;
        }

        final effectiveModel = resolution.resolved!.modelName;
        final resolvedProviderId = resolution.resolved!.providerId;

        final turnRequest = AgentTurnRequest(
          sessionId: effectiveSessionId,
          message: rawInput,
          workspaceId: currentWorkspaceId,
          model: effectiveModel,
          providerInstanceId: resolvedProviderId,
          providerId: resolvedProviderId,
          thinkingMode: thinking ? 'deep' : null,
        );

        try {
          await activeClient.dispatchTurnRequest(turnRequest);
          await activeTurnCompleter.future;
        } catch (e) {
          stderrSink.writeln('Failed to execute turn: $e');
        } finally {
          isTurnRunning = false;
          slashContext.isTurnRunning = false;
          activeTurnCompleter = null;
          if (!lastChunkEndedWithNewline[0]) {
            stdoutSink.writeln();
            lastChunkEndedWithNewline[0] = true;
          }
        }
      }

      return 0;
    } finally {
      await sigintSub?.cancel();
      for (final s in subscriptions) {
        await s.cancel();
      }
      subscriptions.clear();
      await history.save();
      await lineReader.dispose();
      if (shouldDisposeClient) {
        try {
          await activeClient.dispose();
        } catch (_) {}
      }
    }
  }
}
