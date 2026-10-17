import 'package:logging/logging.dart';

import 'conversation_destination.dart';

/// Debug-only diagnostic surface for conversation back/forward navigation.
///
/// Emits one `[NavTrace]` line per navigation decision so a live runtime can be
/// filtered with `grep NavTrace`. Records go through the root logger, which the
/// Client pins to [Level.INFO] only in debug builds and to [Level.OFF]
/// otherwise, so this surface has no runtime flag and no release-build output.
///
/// Only bounded fragments of a decision belong here: the destination kind, short
/// id prefixes, and the route the decision produced. Never log credentials,
/// tokens, message content, or a redirect value that carries them.
final Logger _navTraceLogger = Logger('NavTrace');

/// Short, stable fragment of a device/session id for compact log lines.
String shortId(String? id) {
  if (id == null || id.isEmpty) return '-';
  return id.length <= 8 ? id : id.substring(0, 8);
}

String destTrace(ConversationDestination? dest) {
  if (dest == null) return 'null';
  final kind = switch (dest.kind) {
    ConversationDestinationKind.session => 'session',
    ConversationDestinationKind.newConversation => 'new',
    ConversationDestinationKind.conversationsList => 'list',
  };
  final workspace = dest.workspaceId == null || dest.workspaceId!.isEmpty
      ? ''
      : '+ws:${shortId(dest.workspaceId)}';
  return '$kind(${shortId(dest.deviceId)}/${shortId(dest.sessionId)}$workspace)';
}

String stackTrace(List<ConversationDestination> stack) =>
    stack.isEmpty ? '[]' : '[${stack.map(destTrace).join(' > ')}]';

String historyTrace({
  required List<ConversationDestination> back,
  required ConversationDestination? current,
  required List<ConversationDestination> forward,
}) => 'back=${stackTrace(back)} current=${destTrace(current)} fwd=${stackTrace(forward)}';

void navTrace(String event, String details) => _navTraceLogger.info('$event | $details');
