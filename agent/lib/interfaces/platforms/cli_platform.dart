import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/utils/terminal_prompts.dart';

import '../../core/models/message.dart';
import '../../evolution/session_manager.dart';
import '../models/agent_turn_request.dart';
import '../models/delivery/models.dart';
import '../models/gateway_event.dart';
import '../runtime/platform_runtime_bridge.dart';
import 'base_platform.dart';

class CliPlatform extends BasePlatform {
  final _logger = Logger('CliPlatform');
  final String? initialSessionId;
  final String? workspaceId;
  final _eventController = StreamController<GatewayEvent>();
  bool _running = true;
  StreamSubscription<dynamic>? _inputSubscription;
  bool _isFirstAssistantChunk = true;

  CliPlatform({this.initialSessionId, this.workspaceId});

  String get _sessionId => initialSessionId ?? 'default-cli-session';

  @override
  String get platformId => 'cli';

  @override
  PlatformDescriptor get descriptor => const PlatformDescriptor(
    platformFamily: PlatformFamily.cli,
    transport: PlatformTransport.cli,
    platformInstanceId: 'cli',
  );

  @override
  Stream<GatewayEvent> get eventStream => _eventController.stream;

  @override
  Future<void> initialize() async {
    print('--- Sanad Agent CLI (Gateway Mode) ---');
    if (workspaceId != null && workspaceId!.isNotEmpty) {
      print('Workspace Context: $workspaceId');
    }

    try {
      final session = getIt<SessionManager>().getSession(_sessionId);
      if (session != null && session.messages.isNotEmpty) {
        print(
          'Restored ${session.messages.length} messages from session: $_sessionId',
        );
        for (var msg in session.messages) {
          if (msg.role == MessageRole.user) {
            print('\n> ${msg.content}');
          } else if (msg.role == MessageRole.assistant && msg.content != null) {
            print('\n[SANAD]:\n${msg.content}');
          }
        }
      } else {
        print('Started new session: $_sessionId');
      }
    } catch (e) {
      _logger.warning('Failed to load session history: $e');
    }

    print('\nType your message (or "exit" to quit):');
    getIt<PlatformRuntimeBridge>().registerSessionHandlers(
      _sessionId,
      permissionHandler: _handlePermissionRequest,
    );
    _attachInputLoop(showPrompt: true);
  }

  void _attachInputLoop({required bool showPrompt}) {
    _inputSubscription = stdin
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _handleInputLine,
          onError: (Object error, StackTrace stackTrace) {
            _logger.warning(
              'Error reading from stdin: $error',
              error,
              stackTrace,
            );
          },
        );

    if (showPrompt) {
      stdout.write('\n> ');
    }
  }

  void _handleInputLine(String input) {
    if (!_running) {
      return;
    }

    if (input.toLowerCase() == 'exit') {
      _running = false;
      print('CLI Platform shutting down...');
      exit(0);
    }

    if (input.trim().isEmpty) {
      stdout.write('\n> ');
      return;
    }

    _isFirstAssistantChunk = true;

    _eventController.add(
      GatewayEvent(
        sessionId: _sessionId,
        platformId: platformId,
        message: Message(role: MessageRole.user, content: input),
        turnRequest: AgentTurnRequest(
          sessionId: _sessionId,
          message: input,
          workspaceId: workspaceId,
          metadata: CommandAuthority.stampTurnMetadata(
            const {},
            CommandAuthority.current,
          ),
        ),
      ),
    );
  }

  Future<Map<String, dynamic>> _handlePermissionRequest(
    Map<String, dynamic> payload,
  ) async {
    await _inputSubscription?.cancel();
    _inputSubscription = null;

    try {
      final toolName = payload['tool_name']?.toString() ?? 'unknown-tool';

      // This terminal has no Sanad Client attached and never collects
      // secrets: the request is skipped so the turn can continue.
      if (toolName == 'system_request_secret') {
        print(
          '\nThe agent requested a secret. Secrets are entered only in the '
          'Sanad Client; skipping.',
        );
        return {
          'request_id': payload['request_id'],
          'allowed': false,
          'decision': 'deny',
        };
      }

      if (toolName == 'system_ask_user') {
        print('\n=== 💬 Clarifying Questions ===');
        final questionsRaw = payload['questions'];
        final questions = questionsRaw is List ? questionsRaw : const [];
        final answersPayload = <Map<String, String>>[];

        for (var i = 0; i < questions.length; i++) {
          final qMap = Map<String, dynamic>.from(questions[i] as Map);
          final qText = qMap['question']?.toString() ?? '';
          final optionsRaw = qMap['options'];
          final options = optionsRaw is List
              ? List<String>.from(optionsRaw.map((o) => o.toString()))
              : const <String>[];

          print('\nQuestion ${i + 1} of ${questions.length}: $qText');

          String chosenAnswer = '';
          if (options.isNotEmpty) {
            final selectOptions = [...options, 'Type custom answer...'];
            final choiceIndex = selectInteractive(
              'Choose an option:',
              selectOptions,
            );
            if (choiceIndex < options.length) {
              chosenAnswer = options[choiceIndex];
            } else {
              stdout.write('Your custom answer: ');
              chosenAnswer = stdin.readLineSync()?.trim() ?? '';
            }
          } else {
            stdout.write('Your answer: ');
            chosenAnswer = stdin.readLineSync()?.trim() ?? '';
          }

          answersPayload.add({'question': qText, 'answer': chosenAnswer});
        }

        return {
          'request_id': payload['request_id'],
          'allowed': true,
          'decision': 'allow',
          'answer': jsonEncode(answersPayload),
        };
      }

      final permissionClass =
          payload['permission_class']?.toString() ?? 'general';
      final workspaceName = payload['workspace_name']?.toString();

      final title = StringBuffer()
        ..writeln('')
        ..write('Permission request for "$toolName"')
        ..write(' (class: $permissionClass)');
      if (workspaceName != null && workspaceName.isNotEmpty) {
        title.write(' in workspace "$workspaceName"');
      }

      final allowIndex = selectInteractive(title.toString(), const [
        'Deny',
        'Allow',
      ]);
      if (allowIndex == 0) {
        return {
          'request_id': payload['request_id'],
          'allowed': false,
          'scope': 'once',
          'decision': 'deny',
        };
      }

      final scopeOptions = <String>['Once', 'Session'];
      if ((payload['workspace_path']?.toString().trim().isNotEmpty ?? false)) {
        scopeOptions.add('Workspace');
      }
      final scopeIndex = selectInteractive(
        'Choose approval scope for "$toolName":',
        scopeOptions,
      );
      final scope = switch (scopeOptions[scopeIndex]) {
        'Session' => 'session',
        'Workspace' => 'workspace',
        _ => 'once',
      };

      return {
        'request_id': payload['request_id'],
        'allowed': true,
        'scope': scope,
        'decision': 'allow',
      };
    } finally {
      if (_running) {
        _attachInputLoop(showPrompt: false);
      }
    }
  }

  @override
  Future<void> sendResponse(GatewayResponse response) async {
    if (response.isToolUse) {
      stdout.writeln('\n🔧 [Calling tool: ${response.toolName}]');
      return;
    }
    if (response.isToolResult) {
      final status = response.isToolError ? 'failed ❌' : 'completed ✓';
      stdout.writeln('  [Tool ${response.toolName} $status]');
      return;
    }

    if (response.message.role == MessageRole.assistant) {
      if (_isFirstAssistantChunk) {
        _isFirstAssistantChunk = false;
        stdout.writeln('\n[SANAD]:');
      }
      if (response.message.content != null &&
          response.message.content!.isNotEmpty) {
        stdout.write(response.message.content);
      }
    }

    if (response.isComplete) {
      print('');
      stdout.write('> ');
    }
  }

  @override
  Future<void> dispose() async {
    _running = false;
    getIt<PlatformRuntimeBridge>().unregisterSession(_sessionId);
    await _inputSubscription?.cancel();
    await _eventController.close();
  }
}
