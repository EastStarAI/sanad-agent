import 'dart:async';

import 'package:logging/logging.dart';

import '../../core/agent_runtime_service.dart';
import '../../core/config.dart';
import '../../core/di.dart';
import '../../core/models/message.dart';
import '../../core/models/user_attachment.dart';
import '../../evolution/attachments/attachment_store.dart';
import '../../evolution/compaction/model_projection_builder.dart';
import '../../evolution/memory/file_memory_store.dart';
import '../../evolution/models/compaction_operation_record.dart';
import '../../plugins/plugin_manager.dart';
import '../agent_context_assembler.dart';
import 'turn_route_state.dart';

/// Host interface providing state to [RunnerContextProjector].
abstract class RunnerContextHost {
  String get sessionId;
  List<Message> get history;
  FileMemoryStore get memoryStore;
  AgentContextAssembler get contextAssembler;
  TurnRouteState get turnRoute;
  String? get activeModel;
  PluginManager get pluginManager;

  /// Resolves the session attachment store, including the registration
  /// fallback used by isolated runner tests.
  AttachmentStore? get attachmentStore;

  /// Whether the admitted turn route accepts image input.
  bool get supportsImageInput;
  Future<bool> maybeRunPreflightCompaction({
    String? runtimeSystemPrompt,
    required List<Message> prospectiveHistory,
  });
}

/// Projector responsible for building effective provider histories,
/// injecting multi-tier context (stable, memory, workspace, template),
/// and running preflight compaction checks.
class RunnerContextProjector {
  final RunnerContextHost host;
  final Logger _logger;

  /// Active compaction boundary of the most recently built provider
  /// projection; `null` when it has none or the projection was unavailable.
  CompactionOperationRecord? activeProjectionBoundary;

  RunnerContextProjector(this.host, {Logger? logger})
    : _logger = logger ?? Logger('RunnerContextProjector');

  /// Assembles the effective message list sent to the LLM on every turn.
  List<Message> buildEffectiveHistory({String? runtimeSystemPrompt}) {
    final effectiveHistory = List<Message>.from(providerConversationMessages());

    final memorySections = <String>[];
    final memoryBlock = host.memoryStore.formatForSystemPrompt('memory');
    if (memoryBlock != null) {
      memorySections.add(memoryBlock);
    }
    final userBlock = host.memoryStore.formatForSystemPrompt('user');
    if (userBlock != null) {
      memorySections.add(userBlock);
    }
    host.contextAssembler.setVolatile(
      memoryContext: memorySections.join('\n\n'),
      sessionId: host.sessionId,
      model: host.turnRoute.effectiveModel ?? host.activeModel,
      provider: contextProviderTemplate(),
    );

    if (runtimeSystemPrompt != null) {
      host.contextAssembler.setContext(runtimeSystemPrompt);
    }

    final systemContent = host.contextAssembler.assemble();
    if (systemContent != null) {
      effectiveHistory.insert(
        0,
        Message(role: MessageRole.system, content: systemContent),
      );
    }
    return effectiveHistory;
  }

  Future<List<Message>> prepareProviderHistory({
    String? runtimeSystemPrompt,
  }) async {
    var effectiveHistory = buildEffectiveHistory(
      runtimeSystemPrompt: runtimeSystemPrompt,
    );
    effectiveHistory = await host.pluginManager.runPreExecution(
      effectiveHistory,
    );
    if (await host.maybeRunPreflightCompaction(
      runtimeSystemPrompt: runtimeSystemPrompt,
      prospectiveHistory: effectiveHistory,
    )) {
      effectiveHistory = buildEffectiveHistory(
        runtimeSystemPrompt: runtimeSystemPrompt,
      );
      effectiveHistory = await host.pluginManager.runPreExecution(
        effectiveHistory,
      );
    }
    return _projectUserAttachments(effectiveHistory);
  }

  /// Projects agent-local attachments into provider-visible content.
  ///
  /// Image attachments are retained as native parts only when the admitted
  /// route supports image input; every other attachment is described by its
  /// resolved path so the model inspects it with a scoped tool instead of
  /// inferring contents from a file name.
  static Future<List<Message>> projectUserAttachmentsForProvider({
    required AttachmentStore store,
    required String sessionId,
    required List<Message> messages,
    bool supportsImageInput = false,
  }) async {
    final projected = <Message>[];
    for (final message in messages) {
      if (message.role != MessageRole.user || message.attachments.isEmpty) {
        projected.add(message);
        continue;
      }
      final remainingAttachments = <UserAttachment>[];
      final textProjectedAttachments = <UserAttachment>[];
      for (final attachment in message.attachments) {
        final isImage =
            attachment.kind == UserAttachmentKind.image ||
            attachment.mimeType.toLowerCase().startsWith('image/');
        if (supportsImageInput && isImage) {
          remainingAttachments.add(attachment);
        } else {
          textProjectedAttachments.add(attachment);
        }
      }

      if (textProjectedAttachments.isEmpty) {
        projected.add(message.copyWith(attachments: remainingAttachments));
        continue;
      }

      final lines = <String>[
        if (message.content != null && message.content!.isNotEmpty)
          message.content!,
        '',
        'Agent-local attachments (inspect only with the appropriate tool):',
      ];
      for (final attachment in textProjectedAttachments) {
        try {
          final path = await store.resolvePath(
            sessionId: sessionId,
            attachmentId: attachment.id,
          );
          lines.add(
            '- ${attachment.safeName} (${attachment.kind.name}): $path',
          );
        } on AttachmentStoreException {
          lines.add(
            '- ${attachment.safeName} (${attachment.kind.name}): unavailable',
          );
        }
      }
      final hasProjectedImages = textProjectedAttachments.any(
        (a) =>
            a.kind == UserAttachmentKind.image ||
            a.mimeType.toLowerCase().startsWith('image/'),
      );
      if (hasProjectedImages) {
        lines.add(
          'Use the scoped read/list tools for files; image inspection is not supported by the current model route; do not infer file contents from names.',
        );
      } else {
        lines.add(
          'Use the scoped read/list tools for files; do not infer file contents from names.',
        );
      }
      projected.add(
        message.copyWith(
          content: lines.join('\n').trim(),
          attachments: remainingAttachments,
        ),
      );
    }
    return projected;
  }

  Future<List<Message>> _projectUserAttachments(
    List<Message> effectiveHistory,
  ) async {
    final store = host.attachmentStore;
    if (store == null) return effectiveHistory;
    return RunnerContextProjector.projectUserAttachmentsForProvider(
      store: store,
      sessionId: host.sessionId,
      messages: effectiveHistory,
      supportsImageInput: host.supportsImageInput,
    );
  }

  /// Provider conversation for the next request: the active model projection
  /// when available, otherwise canonical history. Records the projection's
  /// active compaction boundary, or clears it on fallback, so post-boundary
  /// usage is attributed to the request that was actually built.
  List<Message> providerConversationMessages() {
    if (getIt.isRegistered<ModelProjectionBuilder>()) {
      try {
        final projection = getIt<ModelProjectionBuilder>().buildForSession(
          host.sessionId,
        );
        activeProjectionBoundary = projection.activeBoundary;
        return projection.conversationMessages;
      } catch (error) {
        _logger.warning(
          'Compaction projection unavailable for ${host.sessionId}: $error',
        );
      }
    }
    activeProjectionBoundary = null;
    return host.history;
  }

  String? contextProviderTemplate() {
    if (getIt.isRegistered<AgentRuntimeService>()) {
      try {
        final routing = host.turnRoute.resolveTurnRouting();
        return getIt<AgentRuntimeService>()
            .resolveSignature(
              providerId: routing.providerId,
              modelId: routing.model,
            )
            .templateId;
      } catch (_) {
        // Fall through to the static configuration identity.
      }
    }
    return getIt.isRegistered<Config>()
        ? getIt<Config>().resolveProviderName()
        : null;
  }
}
