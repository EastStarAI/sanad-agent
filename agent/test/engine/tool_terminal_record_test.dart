import 'package:sanad_agent/engine/runtime/tool_terminal_record.dart';
import 'package:test/test.dart';

void main() {
  group('ToolTerminalRecord', () {
    test('cancelled record round-trips through checkpoint output', () {
      final record = ToolTerminalRecord.cancelled(
        toolCallId: 'call-1',
        toolName: 'shell_execute',
        runId: 'run-1',
        generation: 2,
        revision: 42,
      );

      final restored = ToolTerminalRecord.fromCheckpointOutput(
        record.toCheckpointOutput(arguments: const {'command': 'sleep 1'}),
      );

      expect(restored, isNotNull);
      expect(restored!.status, ToolTerminalStatus.cancelled);
      expect(restored.message, ToolTerminalRecord.cancelledMessage);
      expect(restored.revision, 42);
      expect(restored.isTerminalCancelled, isTrue);
    });

    test('history metadata preserves cancelled status', () {
      final record = ToolTerminalRecord.cancelled(
        toolCallId: 'call-2',
        toolName: 'shell_execute',
        runId: 'run-2',
        generation: 1,
      );

      final metadata = record.toHistoryMetadata(modelStepId: 'step-2');
      expect(metadata['status'], 'cancelled');
      expect(metadata['reason'], 'user_stop');
      expect(metadata['model_step_id'], 'step-2');
    });
  });
}
