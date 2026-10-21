import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/request_generation.dart';
import 'package:sanad_client/features/conversations/domain/stores/cache_generation_guard.dart';

void main() {
  late CacheGenerationGuard guard;

  setUp(() {
    guard = CacheGenerationGuard();
  });

  group('CacheGenerationGuard', () {
    test('advanceGeneration increments generation per section independently', () {
      final gen1 = guard.advanceGeneration('dev-1', null);
      final gen2 = guard.advanceGeneration('dev-1', null);
      final genWs = guard.advanceGeneration('dev-1', 'ws-1');

      expect(gen1.value, 1);
      expect(gen2.value, 2);
      expect(genWs.value, 1);

      expect(guard.isCurrent(gen2, 'dev-1', null), isTrue);
      expect(guard.isCurrent(gen1, 'dev-1', null), isFalse);
      expect(guard.isCurrent(genWs, 'dev-1', 'ws-1'), isTrue);
    });

    test('advanceWorkspacesGeneration increments per device', () {
      final genA1 = guard.advanceWorkspacesGeneration('dev-A');
      final genA2 = guard.advanceWorkspacesGeneration('dev-A');
      final genB1 = guard.advanceWorkspacesGeneration('dev-B');

      expect(genA1.value, 1);
      expect(genA2.value, 2);
      expect(genB1.value, 1);

      expect(guard.isCurrentWorkspaceGeneration(genA2, 'dev-A'), isTrue);
      expect(guard.isCurrentWorkspaceGeneration(genA1, 'dev-A'), isFalse);
      expect(guard.isCurrentWorkspaceGeneration(genB1, 'dev-B'), isTrue);
    });

    test('currentGeneration returns initial for unseen sections', () {
      expect(guard.currentGeneration('dev-x', 'ws-x'), RequestGeneration.initial);
      expect(guard.currentWorkspaceGeneration('dev-x'), RequestGeneration.initial);
    });

    test('clearDevice removes only target device generations', () {
      final genA = guard.advanceGeneration('dev-A', 'ws-1');
      final wsGenA = guard.advanceWorkspacesGeneration('dev-A');
      final genB = guard.advanceGeneration('dev-B', 'ws-1');
      final wsGenB = guard.advanceWorkspacesGeneration('dev-B');

      guard.clearDevice('dev-A');

      expect(guard.isCurrent(genA, 'dev-A', 'ws-1'), isFalse);
      expect(guard.isCurrentWorkspaceGeneration(wsGenA, 'dev-A'), isFalse);
      expect(guard.isCurrent(genB, 'dev-B', 'ws-1'), isTrue);
      expect(guard.isCurrentWorkspaceGeneration(wsGenB, 'dev-B'), isTrue);
    });

    test('reset clears all generations', () {
      final gen = guard.advanceGeneration('dev-1', null);
      final wsGen = guard.advanceWorkspacesGeneration('dev-1');

      guard.reset();

      expect(guard.isCurrent(gen, 'dev-1', null), isFalse);
      expect(guard.isCurrentWorkspaceGeneration(wsGen, 'dev-1'), isFalse);
    });
  });
}
