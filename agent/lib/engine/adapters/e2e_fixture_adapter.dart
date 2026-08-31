import 'dart:convert';

import '../../capabilities/models/tool_schema.dart';
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
class E2eFixtureAdapter implements LLMAdapter {
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

  const E2eFixtureAdapter();

  AgentResponse _response(List<Message> history, List<ToolSchema>? tools) {
    String? latestUserContent;
    for (final message in history) {
      if (message.role == MessageRole.user) {
        latestUserContent = message.content ?? '';
      }
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
      return AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: truthfulInterruption
              ? shellCrashResponseText
              : 'INVALID_SHELL_INTERRUPTION_RESULT',
        ),
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

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async => _response(history, tools);

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield _response(history, tools);
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
  Future<int> getContextLimit([String? modelOverride]) async => 8192;
}
