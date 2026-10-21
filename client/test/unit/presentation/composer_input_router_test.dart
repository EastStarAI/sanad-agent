import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/utils/composer_input_router.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/utils/app_platform.dart';

class _FakeSessionMessagesCubit extends Fake implements SessionMessagesCubit {
  @override
  SessionMessagesState get state => const SessionMessagesState();

  @override
  Stream<SessionMessagesState> get stream => const Stream.empty();
}

void main() {
  setUp(() {
    AppPlatform.overrideIsMobile = null;
    AppPlatform.overrideIsDesktop = null;
  });

  tearDown(() {
    AppPlatform.overrideIsMobile = null;
    AppPlatform.overrideIsDesktop = null;
  });

  final localAgent = DeviceConfig(
    id: 'agent-local',
    name: 'Local Agent',
    isOnline: true,
    metadata: const {'is_local_candidate': true},
  );

  final remoteAgent = DeviceConfig(
    id: 'agent-remote',
    name: 'Remote Agent',
    isOnline: true,
    metadata: const {'is_local_candidate': false},
  );

  group('ComposerInputRouter.detectFormatKind', () {
    test('detects safe image formats', () {
      expect(ComposerInputRouter.detectFormatKind('photo.png'), ComposerItemFormatKind.safeImage);
      expect(ComposerInputRouter.detectFormatKind('photo.PNG'), ComposerItemFormatKind.safeImage);
      expect(ComposerInputRouter.detectFormatKind('photo.jpg'), ComposerItemFormatKind.safeImage);
      expect(ComposerInputRouter.detectFormatKind('photo.jpeg'), ComposerItemFormatKind.safeImage);
      expect(ComposerInputRouter.detectFormatKind('photo.webp'), ComposerItemFormatKind.safeImage);
      expect(ComposerInputRouter.detectFormatKind('photo.gif'), ComposerItemFormatKind.safeImage);
    });

    test('detects unsafe image formats', () {
      expect(ComposerInputRouter.detectFormatKind('image.heic'), ComposerItemFormatKind.unsafeImage);
      expect(ComposerInputRouter.detectFormatKind('image.heif'), ComposerItemFormatKind.unsafeImage);
      expect(ComposerInputRouter.detectFormatKind('image.tiff'), ComposerItemFormatKind.unsafeImage);
      expect(ComposerInputRouter.detectFormatKind('image.tif'), ComposerItemFormatKind.unsafeImage);
      expect(ComposerInputRouter.detectFormatKind('image.bmp'), ComposerItemFormatKind.unsafeImage);
      expect(ComposerInputRouter.detectFormatKind('icon.svg'), ComposerItemFormatKind.unsafeImage);
      expect(ComposerInputRouter.detectFormatKind('icon.ico'), ComposerItemFormatKind.unsafeImage);
    });

    test('detects non-image formats', () {
      expect(ComposerInputRouter.detectFormatKind('doc.pdf'), ComposerItemFormatKind.nonImage);
      expect(ComposerInputRouter.detectFormatKind('notes.txt'), ComposerItemFormatKind.nonImage);
      expect(ComposerInputRouter.detectFormatKind('readme.md'), ComposerItemFormatKind.nonImage);
      expect(ComposerInputRouter.detectFormatKind('archive.zip'), ComposerItemFormatKind.nonImage);
      expect(ComposerInputRouter.detectFormatKind('code.dart'), ComposerItemFormatKind.nonImage);
    });
  });

  group('ComposerInputRouter.isSameMachineAgent', () {
    test('returns true only when desktop and agent is local candidate', () {
      expect(ComposerInputRouter.isSameMachineAgent(localAgent), isTrue);
      expect(ComposerInputRouter.isSameMachineAgent(remoteAgent), isFalse);
      expect(ComposerInputRouter.isSameMachineAgent(null), isFalse);
    });

    test('returns false when on mobile regardless of agent flag', () {
      AppPlatform.overrideIsMobile = true;
      expect(ComposerInputRouter.isSameMachineAgent(localAgent), isFalse);
    });

    test('returns false on a non-desktop client such as web', () {
      AppPlatform.overrideIsMobile = false;
      AppPlatform.overrideIsDesktop = false;
      expect(ComposerInputRouter.isSameMachineAgent(localAgent), isFalse);
    });
  });

  group('ComposerRoutableItem byte source and naming', () {
    test('loadBytes prefers the originating file reader over an unreadable path', () async {
      final item = ComposerRoutableItem(
        path: 'blob:https://app.example/1234',
        name: 'notes.pdf',
        sizeBytes: 3,
        readBytes: () async => Uint8List.fromList([4, 5, 6]),
      );
      expect(await item.loadBytes(), [4, 5, 6]);
    });

    test('pasted image name carries the extension of the format actually read', () {
      final item = ComposerRoutableItem.fromImageBytes(
        bytes: Uint8List.fromList([1]),
        formatName: 'png',
        suggestedName: 'IMG_0042.heic',
      );
      expect(item.name, 'IMG_0042.png');
      expect(ComposerInputRouter.detectFormatKind(item.name!), ComposerItemFormatKind.safeImage);
      expect(
        ComposerRoutableItem.fromImageBytes(bytes: Uint8List.fromList([1]), formatName: 'jpg').name,
        'pasted-image.jpg',
      );
    });
  });

  group('ComposerInputRouter.decideRoute', () {
    const smallSize = 1024 * 1024; // 1 MiB
    const largeSize = 6 * 1024 * 1024; // 6 MiB

    test('safe image <= 5 MiB routes to attachment when supported', () {
      const item = ComposerRoutableItem(
        path: '/tmp/photo.png',
        name: 'photo.png',
        sizeBytes: smallSize,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: item,
          isSameMachine: true,
          supportsAttachments: true,
        ),
        ComposerRoutingDecision.attachment,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: item,
          isSameMachine: false,
          supportsAttachments: true,
        ),
        ComposerRoutingDecision.attachment,
      );
    });

    test('safe image <= 5 MiB falls back to token on local machine when attachments unsupported', () {
      const item = ComposerRoutableItem(
        path: '/tmp/photo.png',
        name: 'photo.png',
        sizeBytes: smallSize,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: item,
          isSameMachine: true,
          supportsAttachments: false,
        ),
        ComposerRoutingDecision.filePathToken,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: item,
          isSameMachine: false,
          supportsAttachments: false,
        ),
        ComposerRoutingDecision.rejectUnsupported,
      );
    });

    test('safe image > 5 MiB routes to token on same machine without rejection, rejects on remote', () {
      const item = ComposerRoutableItem(
        path: '/tmp/huge.png',
        name: 'huge.png',
        sizeBytes: largeSize,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: item,
          isSameMachine: true,
          supportsAttachments: true,
        ),
        ComposerRoutingDecision.filePathToken,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: item,
          isSameMachine: false,
          supportsAttachments: true,
        ),
        ComposerRoutingDecision.rejectTooLarge,
      );
    });

    test('unsafe image routes to token on local agent, attachment on remote <= 5 MiB', () {
      const smallHeic = ComposerRoutableItem(
        path: '/tmp/photo.heic',
        name: 'photo.heic',
        sizeBytes: smallSize,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: smallHeic,
          isSameMachine: true,
          supportsAttachments: true,
        ),
        ComposerRoutingDecision.filePathToken,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: smallHeic,
          isSameMachine: false,
          supportsAttachments: true,
        ),
        ComposerRoutingDecision.attachment,
      );

      const largeHeic = ComposerRoutableItem(
        path: '/tmp/huge.heic',
        name: 'huge.heic',
        sizeBytes: largeSize,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: largeHeic,
          isSameMachine: false,
          supportsAttachments: true,
        ),
        ComposerRoutingDecision.rejectTooLarge,
      );
    });

    test('non-image file routes to token on local agent, attachment on remote <= 5 MiB', () {
      const doc = ComposerRoutableItem(
        path: '/tmp/report.pdf',
        name: 'report.pdf',
        sizeBytes: smallSize,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: doc,
          isSameMachine: true,
          supportsAttachments: true,
        ),
        ComposerRoutingDecision.filePathToken,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: doc,
          isSameMachine: false,
          supportsAttachments: true,
        ),
        ComposerRoutingDecision.attachment,
      );

      const hugeDoc = ComposerRoutableItem(
        path: '/tmp/big.pdf',
        name: 'big.pdf',
        sizeBytes: largeSize,
      );

      expect(
        ComposerInputRouter.decideRoute(
          item: hugeDoc,
          isSameMachine: false,
          supportsAttachments: true,
        ),
        ComposerRoutingDecision.rejectTooLarge,
      );
    });
  });

  group('ComposerInputRouter.routeItems execution', () {
    late SlashCommandTextController controller;
    late ConversationInputCubit inputCubit;

    setUp(() {
      controller = SlashCommandTextController();
      inputCubit = ConversationInputCubit(messagesCubit: _FakeSessionMessagesCubit());
    });

    tearDown(() async {
      controller.dispose();
      await inputCubit.close();
    });

    test('routes mixed batch element-by-element and deduplicates same paths', () async {
      const capability = Capability(supportsAttachments: true);
      final items = [
        ComposerRoutableItem(
          path: '/tmp/readme.md',
          name: 'readme.md',
          bytes: Uint8List(100),
          sizeBytes: 100,
        ),
        ComposerRoutableItem(
          path: '/tmp/screenshot.png',
          name: 'screenshot.png',
          bytes: Uint8List(200),
          sizeBytes: 200,
        ),
        // Duplicate path
        ComposerRoutableItem(
          path: '/tmp/readme.md',
          name: 'readme.md',
          bytes: Uint8List(100),
          sizeBytes: 100,
        ),
      ];

      await ComposerInputRouter.routeItems(
        items: items,
        controller: controller,
        inputCubit: inputCubit,
        activeAgent: localAgent,
        capability: capability,
        source: DraftAttachmentSource.drop,
      );

      // On local agent:
      // readme.md becomes a file path token
      expect(controller.fileTokensByMarker, hasLength(1));
      expect(controller.fileTokensByMarker.values.single.fileName, 'readme.md');

      // screenshot.png (safe image <= 5 MiB) becomes a draft attachment
      expect(inputCubit.state.draftAttachments, hasLength(1));
      expect(inputCubit.state.draftAttachments.single.name, 'screenshot.png');
    });

    test('reports clear error on remote agent when item > 5 MiB', () async {
      const capability = Capability(supportsAttachments: true);
      final item = ComposerRoutableItem(
        path: '/tmp/large.zip',
        name: 'large.zip',
        bytes: Uint8List(6 * 1024 * 1024),
        sizeBytes: 6 * 1024 * 1024,
      );

      await ComposerInputRouter.routeItem(
        item: item,
        controller: controller,
        inputCubit: inputCubit,
        activeAgent: remoteAgent,
        capability: capability,
        source: DraftAttachmentSource.picker,
      );

      expect(
        inputCubit.state.attachmentError,
        const DraftAttachmentError(DraftAttachmentErrorKind.tooLarge, limit: 5 * 1024 * 1024),
      );
      expect(inputCubit.state.draftAttachments, isEmpty);
      expect(controller.fileTokensByMarker, isEmpty);
    });
  });
}
