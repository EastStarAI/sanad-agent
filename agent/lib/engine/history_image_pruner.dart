import '../core/models/message.dart';
import '../core/models/tool_execution_result.dart';

/// Visible replacement for pixels removed after their model-processing window.
const String prunedHistoryImageMarker =
    '[image data removed after model processing]';

/// Canonical rich-history retention defaults.
const int retainedCompletedImageTurns = 3;
const int maxRetainedHistoryImageBytes = 24 * 1024 * 1024;

class HistoryImagePruneResult {
  final List<Message> messages;
  final bool changed;
  final int retainedImageBytes;

  const HistoryImagePruneResult({
    required this.messages,
    required this.changed,
    required this.retainedImageBytes,
  });
}

/// Pure deterministic transform for processed images in canonical history.
class HistoryImagePruner {
  static HistoryImagePruneResult prune(
    List<Message> history, {
    int recentCompletedTurns = retainedCompletedImageTurns,
    int maxRetainedBytes = maxRetainedHistoryImageBytes,
  }) {
    if (recentCompletedTurns < 0 || maxRetainedBytes < 0) {
      throw ArgumentError(
        'History image retention limits must be non-negative',
      );
    }

    final completedTurnByMessage = List<int?>.filled(history.length, null);
    var turnStart = 0;
    var completedTurns = 0;
    for (var index = 0; index < history.length; index++) {
      if (!_isCompletedAssistant(history[index])) continue;
      for (var member = turnStart; member <= index; member++) {
        completedTurnByMessage[member] = completedTurns;
      }
      completedTurns++;
      turnStart = index + 1;
    }

    final prune = <({int messageIndex, int blockIndex})>{};
    final retained =
        <({int messageIndex, int blockIndex, int bytes, int turn})>[];
    final oldestPreservedTurn = completedTurns - recentCompletedTurns;
    for (var messageIndex = 0; messageIndex < history.length; messageIndex++) {
      final result = history[messageIndex].toolResult;
      if (result == null) continue;
      final turn = completedTurnByMessage[messageIndex];
      for (
        var blockIndex = 0;
        blockIndex < result.blocks.length;
        blockIndex++
      ) {
        final block = result.blocks[blockIndex];
        if (block is! ToolImageBlock) continue;
        if (turn != null && turn < oldestPreservedTurn) {
          prune.add((messageIndex: messageIndex, blockIndex: blockIndex));
        } else {
          retained.add((
            messageIndex: messageIndex,
            blockIndex: blockIndex,
            bytes: _decodedBytes(block.dataBase64),
            turn: turn ?? completedTurns,
          ));
        }
      }
    }

    var retainedBytes = retained.fold<int>(
      0,
      (sum, image) => sum + image.bytes,
    );
    for (final image in retained) {
      if (retainedBytes <= maxRetainedBytes) break;
      // Images in the uncompleted current loop are never eligible for the cap.
      if (completedTurnByMessage[image.messageIndex] == null) continue;
      prune.add((
        messageIndex: image.messageIndex,
        blockIndex: image.blockIndex,
      ));
      retainedBytes -= image.bytes;
    }
    if (prune.isEmpty) {
      return HistoryImagePruneResult(
        messages: List<Message>.unmodifiable(history),
        changed: false,
        retainedImageBytes: retainedBytes,
      );
    }

    final transformed = List<Message>.of(history);
    final byMessage = <int, Set<int>>{};
    for (final target in prune) {
      byMessage
          .putIfAbsent(target.messageIndex, () => <int>{})
          .add(target.blockIndex);
    }
    for (final entry in byMessage.entries) {
      final message = history[entry.key];
      final result = message.toolResult!;
      final blocks = <ToolResultBlock>[
        for (var index = 0; index < result.blocks.length; index++)
          if (entry.value.contains(index))
            ToolTextBlock(text: prunedHistoryImageMarker)
          else
            result.blocks[index],
      ];
      final replacement = ToolExecutionResult(
        schemaVersion: result.schemaVersion,
        blocks: blocks,
        isError: result.isError,
        errorCode: result.errorCode,
      );
      transformed[entry.key] = message.copyWith(toolResult: replacement);
    }
    return HistoryImagePruneResult(
      messages: List<Message>.unmodifiable(transformed),
      changed: true,
      retainedImageBytes: retainedBytes,
    );
  }

  static bool _isCompletedAssistant(Message message) =>
      message.role == MessageRole.assistant &&
      (message.toolCalls == null || message.toolCalls!.isEmpty);

  static int _decodedBytes(String base64) {
    final padding = base64.endsWith('==')
        ? 2
        : base64.endsWith('=')
        ? 1
        : 0;
    return (base64.length * 3 ~/ 4) - padding;
  }
}
