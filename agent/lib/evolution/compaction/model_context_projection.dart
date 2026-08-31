import 'package:sanad_agent/core/models/message.dart';

import '../models/compaction_operation_record.dart';

/// Canonical conversation row with durable `messages.id` identity.
class PersistedMessage {
  final int rowId;
  final Message message;

  const PersistedMessage({required this.rowId, required this.message});
}

/// Full canonical transcript ordered by durable row identity.
class CanonicalConversationTimeline {
  final String sessionId;
  final List<PersistedMessage> messages;

  const CanonicalConversationTimeline({
    required this.sessionId,
    required this.messages,
  });
}

/// Ephemeral provider-facing projection built from canonical history.
///
/// System/runtime context remains outside this value; [AgentContextAssembler]
/// prepends the single system message at request time.
class ModelContextProjection {
  final String sessionId;
  final CompactionOperationRecord? activeBoundary;
  final List<Message> conversationMessages;

  const ModelContextProjection({
    required this.sessionId,
    this.activeBoundary,
    required this.conversationMessages,
  });

  bool get usesCompactionBoundary => activeBoundary != null;
}
