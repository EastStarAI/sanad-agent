import 'dart:async';

import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';

import 'local_workspace_runtime_service.dart';

/// Coordinates runtime-rich turn requests before they reach the core agent.
///
/// This layer deliberately sits between the Sanad transport contract and the
/// engine so we can rebuild workspace context, permissions, skills, and MCP
/// state on every turn without coupling that orchestration to [AgentRunner].
class LocalRuntimeOrchestrator {
  LocalRuntimeOrchestrator(
    this._workspaceRuntimeService,
    this._runtimeCatalog, {
    RuntimeContextBuilder? runtimeContextBuilder,
  }) : _runtimeContextBuilder =
           runtimeContextBuilder ?? const RuntimeContextBuilder();

  final LocalWorkspaceRuntimeService _workspaceRuntimeService;
  final LocalRuntimeCatalog _runtimeCatalog;
  final RuntimeContextBuilder _runtimeContextBuilder;

  Future<Map<String, dynamic>> buildSessionMetadata(
    AgentTurnRequest request,
  ) async {
    final metadata = Map<String, dynamic>.from(request.toMetadata());
    final workspaceId = request.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) {
      return metadata;
    }

    final workspace = await _workspaceRuntimeService.describeWorkspace(
      workspaceId,
    );
    if (workspace != null) {
      if (workspace['is_missing'] == true) {
        throw StateError(
          'Workspace folder is unavailable. Reconnect it before continuing.',
        );
      }
      final resolvedWorkspaceId = workspace['id']?.toString();
      if (resolvedWorkspaceId != null && resolvedWorkspaceId.isNotEmpty) {
        metadata['workspace_id'] = resolvedWorkspaceId;
      }
      metadata['workspace'] = workspace;
      final workspaceName = workspace['name']?.toString();
      final workspacePath = workspace['path'] as String?;
      if (workspaceName != null && workspaceName.isNotEmpty) {
        metadata['workspace_name'] = workspaceName;
      }
      if (workspacePath != null && workspacePath.isNotEmpty) {
        metadata['workspace_path'] = workspacePath;
      }
    }
    return metadata;
  }

  Stream<String> streamTurn({
    required AgentRunner agentRunner,
    required AgentTurnRequest request,
    Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
    void Function()? onSteerContinuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) {
    agentRunner.setTurnRequestId(request.requestId);
    final receivedAt = _readReceivedAt(request);
    return Stream.fromFuture(
      _runtimeCatalog.buildTools(
        registry: agentRunner.registry,
        request: request,
      ),
    ).asyncExpand((tools) {
      agentRunner.registry.registerTools(tools);
      return Stream.fromFuture(
        _buildRuntimeContext(request, agentRunner),
      ).asyncExpand((runtimeContext) {
        final effectiveProviderId = request.effectiveProviderInstanceId;
        if (runtimeContext == null &&
            effectiveProviderId == null &&
            request.model == null &&
            request.thinkingMode == null) {
          return agentRunner.streamMessage(
            request.message,
            receivedAt: receivedAt,
            onToolEvent: onToolEvent,
            onSteerContinuation: onSteerContinuation,
            onThoughtDelta: onThoughtDelta,
            onReasoningDelta: onReasoningDelta,
          );
        }
        return agentRunner.streamMessage(
          request.message,
          runtimeSystemPrompt: runtimeContext,
          providerId: effectiveProviderId,
          model: request.model,
          thinkingMode: request.thinkingMode,
          receivedAt: receivedAt,
          onToolEvent: onToolEvent,
          onSteerContinuation: onSteerContinuation,
          onThoughtDelta: onThoughtDelta,
          onReasoningDelta: onReasoningDelta,
        );
      });
    });
  }

  Stream<String> resumeTurn({
    required AgentRunner agentRunner,
    required AgentTurnRequest request,
    Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
    void Function()? onSteerContinuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) {
    agentRunner.setTurnRequestId(request.requestId);
    return Stream.fromFuture(
      _runtimeCatalog.buildTools(
        registry: agentRunner.registry,
        request: request,
      ),
    ).asyncExpand((tools) {
      agentRunner.registry.registerTools(tools);
      return Stream.fromFuture(
        _buildRuntimeContext(request, agentRunner),
      ).asyncExpand((runtimeContext) {
        final effectiveProviderId = request.effectiveProviderInstanceId;
        if (runtimeContext == null &&
            effectiveProviderId == null &&
            request.model == null &&
            request.thinkingMode == null) {
          return agentRunner.resumeStream(
            onToolEvent: onToolEvent,
            onSteerContinuation: onSteerContinuation,
            onThoughtDelta: onThoughtDelta,
            onReasoningDelta: onReasoningDelta,
          );
        }
        return agentRunner.resumeStream(
          runtimeSystemPrompt: runtimeContext,
          providerId: effectiveProviderId,
          model: request.model,
          thinkingMode: request.thinkingMode,
          onToolEvent: onToolEvent,
          onSteerContinuation: onSteerContinuation,
          onThoughtDelta: onThoughtDelta,
          onReasoningDelta: onReasoningDelta,
        );
      });
    });
  }

  Future<String?> _buildRuntimeContext(
    AgentTurnRequest request,
    AgentRunner agentRunner,
  ) async {
    final workspaceId = request.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) {
      return null;
    }

    final workspace = await _workspaceRuntimeService.describeWorkspace(
      workspaceId,
    );
    final workspacePath = workspace?['path'] as String?;
    if (workspacePath == null || workspacePath.isEmpty) {
      return null;
    }

    final workspaceName = workspace?['name'] as String?;
    final runtimeContext = await _runtimeContextBuilder.build(
      workspacePath: workspacePath,
      workspaceName: workspaceName,
      registry: agentRunner.registry,
    );
    return runtimeContext;
  }

  DateTime? _readReceivedAt(AgentTurnRequest request) {
    final raw = request.metadata['received_at'];
    if (raw == null) {
      return null;
    }
    return DateTime.tryParse(raw.toString());
  }
}
