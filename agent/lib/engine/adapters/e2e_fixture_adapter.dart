import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

import '../../capabilities/models/tool_schema.dart';
import '../../core/models/tool_execution_result.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/message.dart';
import '../../core/models/tool_call.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';
import 'llm_adapter.dart';
import 'llm_request_options.dart';

/// Deterministic provider used only by daemon-backed E2E tests.
///
/// Unlike transport-level fixtures, this adapter runs through AgentRunner and
/// the normal persistence/event pipeline without contacting an external model.
class E2eFixtureAdapter
    implements
        LLMAdapter,
        WireInputUsageMeasurer,
        ToolResultMediaCapabilityProvider {
  static const providerId = 'e2e-provider';
  static const modelId = 'e2e-model';
  static const responseText = 'e2e-success';
  static const permissionToolName = 'system_screenshot';
  static const permissionToolCallId = 'e2e-permission-tool-call';
  static const permissionResponseText = 'SCREEN_OK';
  static const parallelExternalReadPromptPrefix =
      '__SANAD_E2E_PARALLEL_EXTERNAL_READS__';
  static const parallelExternalReadResponseText = 'EXTERNAL_READS_OK';
  static const parallelExternalReadToolName = 'file_read';
  static const memoryToolName = 'memory';
  static const memoryAddPrompt = '__SANAD_E2E_MEMORY_ADD__';
  static const memoryReadPrompt = '__SANAD_E2E_MEMORY_READ__';
  static const runtimeContextPrompt = '__SANAD_E2E_RUNTIME_CONTEXT__';
  static const skillLoadPrompt = '__SANAD_E2E_SKILL_LOAD__';
  static const skillLoadToolName = 'skill_load';
  static const skillLoadToolCallId = 'e2e-skill-load-tool-call';
  static const memoryAddToolCallId = 'e2e-memory-add-tool-call';
  static const memoryReadToolCallId = 'e2e-memory-read-tool-call';
  static const memoryEntry = 'User name is Ahmed Memory E2E';
  static const askUserPrompt = '__SANAD_E2E_ASK_USER_RESTART__';
  static const askUserToolName = 'system_ask_user';
  static const askUserToolCallId = 'e2e-ask-user-tool-call';
  static const askUserResponseText = 'ASK_USER_RESUMED';
  static const shellCrashPromptPrefix = '__SANAD_E2E_SHELL_CRASH__';
  static const shellToolName = 'shell_execute';
  static const shellToolCallId = 'e2e-shell-crash-tool-call';
  static const shellCrashResponseText = 'SHELL_INTERRUPTED_RESUMED';
  static const viewImagePromptPrefix = '__SANAD_E2E_VIEW_IMAGE__';
  static const attachmentImagePrompt = '__SANAD_E2E_ATTACHMENT_IMAGE__';
  static const attachmentImageToolCallId = 'e2e-attachment-image-tool-call';
  static const viewImageToolName = 'view_image';
  static const viewImageToolCallId = 'e2e-view-image-tool-call';
  static const viewImagePixelResponseText = 'PIXELS_MAGENTA';
  static const viewImageTextFallbackResponseText = 'IMAGE_TEXT_ONLY_FALLBACK';
  static const viewImageInvalidResponseText = 'INVALID_IMAGE_RESULT';

  @override
  final ToolResultMediaCapability toolResultMediaCapability;

  const E2eFixtureAdapter({
    this.toolResultMediaCapability = ToolResultMediaCapability.imageToolResults,
  });

  Future<AgentResponse> _response(
    List<Message> history,
    List<ToolSchema>? tools,
  ) async {
    String? latestUserContent;
    for (final message in history) {
      if (message.role == MessageRole.user) {
        latestUserContent = message.content ?? '';
      }
    }
    if (latestUserContent?.contains('The JSON schema version is 1') ?? false) {
      var latestRequest = 'Continue the current task';
      String? explicitGoal;
      for (final message in history.take(history.length - 1)) {
        if (message.role == MessageRole.user &&
            (message.content ?? '').trim().isNotEmpty) {
          latestRequest = message.content!;
          final goalMatch = RegExp(
            r'goal:\s*(.+)',
            caseSensitive: false,
          ).firstMatch(message.content!);
          explicitGoal ??= goalMatch?.group(1)?.trim();
        }
      }
      return AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: jsonEncode({
            'schemaVersion': 1,
            'currentGoal': explicitGoal ?? latestRequest,
            'latestUserRequest': latestRequest,
            'successCriteria': 'Complete the requested work safely',
            'constraints': 'Preserve the active runtime contracts',
            'completedWork': 'Earlier conversation work is preserved',
            'activeState': 'Continue from the current checkpoint',
            'criticalContext': latestRequest,
            'decisions': 'Use the validated current plan',
            'blockers': 'None recorded',
            'filesAndPaths': 'None recorded',
            'pendingAsks': latestRequest,
            'remainingWork': 'Complete and verify the latest user request',
          }),
        ),
        usage: const {
          'prompt_tokens': 1200,
          'cached_input_tokens': 900,
          'completion_tokens': 180,
        },
        model: modelId,
        provider: providerId,
        finishReason: LLMFinishReason.stop,
      );
    }
    if (latestUserContent == runtimeContextPrompt) {
      final markerPattern = RegExp(
        r'^CURRENT_RUNTIME_MARKER=(.+)$',
        multiLine: true,
      );
      String? marker;
      for (final message in history) {
        if (message.role != MessageRole.system) continue;
        marker = markerPattern
            .firstMatch(message.content ?? '')
            ?.group(1)
            ?.trim();
        if (marker != null && marker.isNotEmpty) break;
      }
      return AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: marker ?? 'MISSING_RUNTIME_MARKER',
        ),
        model: modelId,
        provider: providerId,
        finishReason: LLMFinishReason.stop,
      );
    }

    final hasAskUserTool =
        tools?.any((tool) => tool.name == askUserToolName) ?? false;
    if (latestUserContent == askUserPrompt && hasAskUserTool) {
      final hasResult = history.any(
        (message) =>
            message.role == MessageRole.tool &&
            message.toolCallId == askUserToolCallId,
      );
      if (!hasResult) {
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(
                id: askUserToolCallId,
                name: askUserToolName,
                arguments: const {
                  'question': 'Should this task continue after restart?',
                },
              ),
            ],
          ),
          isToolCall: true,
          model: modelId,
          provider: providerId,
          finishReason: LLMFinishReason.toolCalls,
        );
      }
      return AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: askUserResponseText,
        ),
        model: modelId,
        provider: providerId,
        finishReason: LLMFinishReason.stop,
      );
    }

    final isShellCrashScenario =
        latestUserContent?.startsWith(shellCrashPromptPrefix) ?? false;
    final hasShellTool =
        tools?.any((tool) => tool.name == shellToolName) ?? false;
    if (isShellCrashScenario && hasShellTool) {
      Message? toolResult;
      for (final message in history) {
        if (message.role == MessageRole.tool &&
            message.toolCallId == shellToolCallId) {
          toolResult = message;
        }
      }
      if (toolResult == null) {
        final encodedCommand = latestUserContent!.substring(
          shellCrashPromptPrefix.length,
        );
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(
                id: shellToolCallId,
                name: shellToolName,
                arguments: {
                  'command': jsonDecode(encodedCommand).toString(),
                  'timeout_ms': 60000,
                },
              ),
            ],
          ),
          isToolCall: true,
          model: modelId,
          provider: providerId,
          finishReason: LLMFinishReason.toolCalls,
        );
      }
      final truthfulInterruption =
          (toolResult.content?.contains('CRASH_OUTPUT') ?? false) &&
          (toolResult.content?.contains('interrupted') ?? false) &&
          !(toolResult.content?.contains('cancelled by user') ?? false);
      final hasOriginalToolUse = history.any(
        (message) =>
            message.role == MessageRole.assistant &&
            (message.toolCalls ?? const []).any(
              (toolCall) =>
                  toolCall.id == shellToolCallId &&
                  toolCall.name == shellToolName &&
                  toolCall.arguments['command'] != null,
            ),
      );
      return AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: truthfulInterruption && hasOriginalToolUse
              ? shellCrashResponseText
              : 'INVALID_SHELL_INTERRUPTION_RESULT',
        ),
        model: modelId,
        provider: providerId,
        finishReason: LLMFinishReason.stop,
      );
    }

    String? attachmentProjection;
    for (final message in history) {
      if (message.role == MessageRole.user &&
          (message.content ?? '').contains(attachmentImagePrompt)) {
        attachmentProjection = message.content;
      }
    }
    final hasViewImageTool =
        tools?.any((tool) => tool.name == viewImageToolName) ?? false;
    if (attachmentProjection != null && hasViewImageTool) {
      Message? toolResult;
      for (final message in history) {
        if (message.role == MessageRole.tool &&
            message.toolCallId == attachmentImageToolCallId) {
          toolResult = message;
        }
      }
      if (toolResult == null) {
        final projection = attachmentProjection;
        final path = RegExp(
          r'^- .+ \(image\): (.+)$',
          multiLine: true,
        ).firstMatch(projection)?.group(1);
        final projectionIsSafe =
            path != null &&
            path.isNotEmpty &&
            !projection.contains('data_base64') &&
            !projection.contains('dataBase64') &&
            !projection.contains('iVBOR');
        if (!projectionIsSafe) {
          return AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: viewImageInvalidResponseText,
            ),
            model: modelId,
            provider: providerId,
            finishReason: LLMFinishReason.stop,
          );
        }
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(
                id: attachmentImageToolCallId,
                name: viewImageToolName,
                arguments: {'path': path},
              ),
            ],
          ),
          isToolCall: true,
          model: modelId,
          provider: providerId,
          finishReason: LLMFinishReason.toolCalls,
        );
      }
      final imageBlocks =
          toolResult.toolResult?.blocks.whereType<ToolImageBlock>().toList(
            growable: false,
          ) ??
          const <ToolImageBlock>[];
      return AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: switch (imageBlocks) {
            [final imageBlock, ...] => _classifyFixtureImage(imageBlock),
            _ => viewImageInvalidResponseText,
          },
        ),
        model: modelId,
        provider: providerId,
        finishReason: LLMFinishReason.stop,
      );
    }

    final isViewImageScenario =
        latestUserContent?.startsWith(viewImagePromptPrefix) ?? false;
    if (isViewImageScenario && hasViewImageTool) {
      Message? toolResult;
      for (final message in history) {
        if (message.role == MessageRole.tool &&
            message.toolCallId == viewImageToolCallId) {
          toolResult = message;
        }
      }
      if (toolResult == null) {
        final encodedPath = latestUserContent!.substring(
          viewImagePromptPrefix.length,
        );
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(
                id: viewImageToolCallId,
                name: viewImageToolName,
                arguments: {'path': jsonDecode(encodedPath).toString()},
              ),
            ],
          ),
          isToolCall: true,
          model: modelId,
          provider: providerId,
          finishReason: LLMFinishReason.toolCalls,
        );
      }

      await _pauseAfterViewImageResultIfRequested();
      final imageBlocks =
          toolResultMediaCapability ==
              ToolResultMediaCapability.imageToolResults
          ? toolResult.toolResult?.blocks.whereType<ToolImageBlock>().toList(
                  growable: false,
                ) ??
                const <ToolImageBlock>[]
          : const <ToolImageBlock>[];
      final responseText = switch (imageBlocks) {
        [] when toolResult.toolResult?.isError ?? false =>
          viewImageInvalidResponseText,
        [] => viewImageTextFallbackResponseText,
        [final imageBlock, ...] => _classifyFixtureImage(imageBlock),
      };
      return AgentResponse(
        message: Message(role: MessageRole.assistant, content: responseText),
        model: modelId,
        provider: providerId,
        finishReason: LLMFinishReason.stop,
      );
    }

    final hasSkillLoadTool =
        tools?.any((tool) => tool.name == skillLoadToolName) ?? false;
    if (latestUserContent == skillLoadPrompt && hasSkillLoadTool) {
      final hasResult = history.any(
        (message) =>
            message.role == MessageRole.tool &&
            message.toolCallId == skillLoadToolCallId,
      );
      if (!hasResult) {
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(
                id: skillLoadToolCallId,
                name: skillLoadToolName,
                arguments: const {'skill': 'review'},
              ),
            ],
          ),
          isToolCall: true,
          model: modelId,
          provider: providerId,
          finishReason: LLMFinishReason.toolCalls,
        );
      }
      return AgentResponse(
        message: Message(role: MessageRole.assistant, content: 'SKILL_LOADED'),
        model: modelId,
        provider: providerId,
        finishReason: LLMFinishReason.stop,
      );
    }

    final hasMemoryTool =
        tools?.any((tool) => tool.name == memoryToolName) ?? false;
    final memoryToolCallId = latestUserContent == memoryAddPrompt
        ? memoryAddToolCallId
        : latestUserContent == memoryReadPrompt
        ? memoryReadToolCallId
        : null;
    if (hasMemoryTool && memoryToolCallId != null) {
      final hasResult = history.any(
        (message) =>
            message.role == MessageRole.tool &&
            message.toolCallId == memoryToolCallId,
      );
      if (!hasResult) {
        final isAdd = memoryToolCallId == memoryAddToolCallId;
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(
                id: memoryToolCallId,
                name: memoryToolName,
                arguments: isAdd
                    ? const {
                        'action': 'add',
                        'target': 'user',
                        'content': memoryEntry,
                      }
                    : const {'action': 'read', 'target': 'user'},
              ),
            ],
          ),
          isToolCall: true,
          model: modelId,
          provider: providerId,
          finishReason: LLMFinishReason.toolCalls,
        );
      }
      return AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: memoryToolCallId == memoryAddToolCallId
              ? 'MEMORY_STORED'
              : 'MEMORY_READ',
        ),
        model: modelId,
        provider: providerId,
        finishReason: LLMFinishReason.stop,
      );
    }

    final isParallelExternalReadScenario =
        latestUserContent?.startsWith(parallelExternalReadPromptPrefix) ??
        false;
    final hasParallelExternalReadTool =
        tools?.any((tool) => tool.name == parallelExternalReadToolName) ??
        false;
    if (isParallelExternalReadScenario && hasParallelExternalReadTool) {
      final encodedPaths = latestUserContent!.substring(
        parallelExternalReadPromptPrefix.length,
      );
      final paths = (jsonDecode(encodedPaths) as List<dynamic>)
          .map((path) => path.toString())
          .toList(growable: false);
      final toolCalls = [
        for (var index = 0; index < paths.length; index++)
          ToolCall(
            id: 'e2e-external-file-read-$index',
            name: parallelExternalReadToolName,
            arguments: {'path': paths[index]},
          ),
      ];
      final completedToolCallIds = history
          .where((message) => message.role == MessageRole.tool)
          .map((message) => message.toolCallId)
          .whereType<String>()
          .toSet();
      final hasAllResults = toolCalls.every(
        (toolCall) => completedToolCallIds.contains(toolCall.id),
      );
      if (!hasAllResults) {
        return AgentResponse(
          message: Message(role: MessageRole.assistant, toolCalls: toolCalls),
          isToolCall: true,
          model: modelId,
          provider: providerId,
          finishReason: LLMFinishReason.toolCalls,
        );
      }
      return AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: parallelExternalReadResponseText,
        ),
        model: modelId,
        provider: providerId,
        finishReason: LLMFinishReason.stop,
      );
    }

    final hasPermissionTool =
        tools?.any((tool) => tool.name == permissionToolName) ?? false;
    final hasPermissionToolResult = history.any(
      (message) =>
          message.role == MessageRole.tool &&
          message.toolCallId == permissionToolCallId,
    );

    if (hasPermissionTool && !hasPermissionToolResult) {
      return AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(
              id: permissionToolCallId,
              name: permissionToolName,
              arguments: const {'monitor_number': 1},
            ),
          ],
        ),
        isToolCall: true,
        model: modelId,
        provider: providerId,
        finishReason: LLMFinishReason.toolCalls,
      );
    }

    String? platformMarker;
    if (hasPermissionToolResult) {
      final markerPattern = RegExp(r'PLATFORM_MARKER_[A-Za-z0-9_-]+');
      for (final message in history) {
        if (message.role != MessageRole.tool ||
            message.toolCallId != permissionToolCallId) {
          continue;
        }
        platformMarker = markerPattern
            .firstMatch(message.content ?? '')
            ?.group(0);
        if (platformMarker != null) break;
      }
    }

    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: hasPermissionToolResult
            ? platformMarker ?? permissionResponseText
            : responseText,
      ),
      model: modelId,
      provider: providerId,
      finishReason: LLMFinishReason.stop,
    );
  }

  static Future<void> _pauseAfterViewImageResultIfRequested() async {
    final readyPath = Platform.environment['SANAD_E2E_VIEW_IMAGE_PAUSE_FILE'];
    if (readyPath == null || readyPath.isEmpty) return;
    final ready = File(readyPath);
    await ready.parent.create(recursive: true);
    await ready.writeAsString('tool-result-received', flush: true);
    final release = File('$readyPath.release');
    while (!release.existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  static String _classifyFixtureImage(ToolImageBlock block) {
    final decoded = img.decodeImage(base64Decode(block.dataBase64));
    if (decoded == null || decoded.width == 0 || decoded.height == 0) {
      return viewImageInvalidResponseText;
    }
    final pixel = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
    final isMagenta = pixel.r > 180 && pixel.b > 180 && pixel.g < 100;
    return isMagenta
        ? viewImagePixelResponseText
        : viewImageInvalidResponseText;
  }

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async => _response(history, tools);

  @override
  Future<WireInputMeasurement?> measureInput(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async => WireInputMeasurement(
    estimatedTokens:
        (jsonEncode({
                  'history': history
                      .map((message) => message.toJson())
                      .toList(),
                  'tools': tools?.map((tool) => tool.toJson()).toList(),
                }).length /
                4)
            .ceil(),
    stableMaterialFingerprint: jsonEncode(
      tools?.map((tool) => tool.toJson()).toList() ?? const [],
    ),
    inputItemFingerprints: [
      for (final message in history) jsonEncode(message.toJson()),
    ],
  );

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await _response(history, tools);
  }

  @override
  Future<List<ModelOption>> getAvailableModels() async => [
    ModelOption(
      value: modelId,
      label: 'E2E Model',
      provider: providerId,
      supportsReasoning: true,
    ),
  ];

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 32_768;
}
