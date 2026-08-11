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
                arguments: const {'skill': 'review', 'args': '--focus docs'},
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
