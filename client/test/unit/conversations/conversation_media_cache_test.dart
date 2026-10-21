import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_media_byte_cache.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_media_loader_resolver.dart';
import 'package:sanad_client/features/conversations/data/repositories/hosted_view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/view_image_tool_card.dart';
import 'package:sanad_client/infrastructure/socket/hosted_conversation_media.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

void main() {
  group('ConversationMediaByteCache', () {
    String key(String device, String media) => ConversationMediaByteCache.keyFor(
      transport: 'local',
      deviceId: device,
      sessionId: 'session-1',
      kind: 'view-image',
      mediaId: media,
    );

    test('evicts least recently used entries past the byte limit', () {
      final cache = ConversationMediaByteCache(maximumBytes: 10);
      cache.put(key('d', 'a'), Uint8List(4));
      cache.put(key('d', 'b'), Uint8List(4));
      expect(cache.get(key('d', 'a')), isNotNull, reason: 'touching a makes b the oldest');
      cache.put(key('d', 'c'), Uint8List(4));

      expect(cache.get(key('d', 'b')), isNull);
      expect(cache.get(key('d', 'a')), isNotNull);
      expect(cache.get(key('d', 'c')), isNotNull);
      expect(cache.bytes, 8);
      expect(cache.length, 2);
    });

    test('never stores an entry larger than the whole cache', () {
      final cache = ConversationMediaByteCache(maximumBytes: 3);
      cache.put(key('d', 'a'), Uint8List(4));
      expect(cache.length, 0);
    });

    test('keys separate devices and transports for the same media id', () {
      expect(key('device-1', 'm'), isNot(key('device-2', 'm')));
      final hosted = ConversationMediaByteCache.keyFor(
        transport: 'hosted',
        deviceId: 'device-1',
        sessionId: 'session-1',
        kind: 'view-image',
        mediaId: 'm',
      );
      expect(hosted, isNot(key('device-1', 'm')));
    });

    test('account binding drops hosted bytes on sign-out and account change, keeping local bytes', () {
      final cache = ConversationMediaByteCache(maximumBytes: 1024);
      String hosted(String media) => ConversationMediaByteCache.keyFor(
        transport: ConversationMediaByteCache.hostedTransport,
        deviceId: 'cloud-1',
        sessionId: 'session-1',
        kind: 'view-image',
        mediaId: media,
      );
      final local = key('hardware-1', 'local-media');

      cache.bindAccount('user-a');
      cache.put(hosted('a'), Uint8List(4));
      cache.put(local, Uint8List(4));

      cache.bindAccount('user-a');
      expect(cache.get(hosted('a')), isNotNull, reason: 're-binding the same account keeps its media');

      cache.bindAccount(null);
      expect(cache.get(hosted('a')), isNull, reason: 'sign-out or auth loss drops hosted media');
      expect(cache.get(local), isNotNull, reason: 'local device media is not account data');
      expect(cache.bytes, 4);

      cache.bindAccount('user-a');
      cache.put(hosted('b'), Uint8List(4));
      cache.bindAccount('user-b');
      expect(cache.get(hosted('b')), isNull, reason: 'an account change drops the previous account\'s media');
      expect(cache.length, 1);
    });

    test('the shared default is bounded by configuration', () {
      expect(ConversationMediaByteCache.shared.maximumBytes, 64 * 1024 * 1024);
    });
  });

  group('repositories share one cache', () {
    final media = ViewImageMedia.fromJson({
      'media_id': 'a' * 64,
      'name': 'view-image.png',
      'mime_type': 'image/png',
      'width': 1,
      'height': 1,
      'availability': 'available',
    })!;

    ViewImageMediaRepository local(String hardwareId, ConversationMediaByteCache cache, void Function() onRequest) =>
        ViewImageMediaRepository(
          baseUrl: 'http://127.0.0.1:58184',
          hardwareId: hardwareId,
          headerProvider: () async => const {},
          cache: cache,
          clientFactory: () => MockClient((request) async {
            onRequest();
            return http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'});
          }),
        );

    test('a new local repository instance reuses cached bytes, but not across devices', () async {
      final cache = ConversationMediaByteCache(maximumBytes: 1024);
      var requests = 0;
      final first = await local('hardware-1', cache, () => requests++).load(media: media, sessionId: 'session-1').bytes;
      final again = local('hardware-1', cache, () => requests++).load(media: media, sessionId: 'session-1');
      expect(again.cachedBytes, same(first), reason: 'a cache hit is synchronous and the same instance');
      expect(requests, 1);

      await local('hardware-2', cache, () => requests++).load(media: media, sessionId: 'session-1').bytes;
      expect(requests, 2, reason: 'another device never reads hardware-1 bytes');
    });

    test('hosted relay media is cached across resolver calls and scoped by device', () async {
      final cache = ConversationMediaByteCache(maximumBytes: 1024);
      final socket = _FakeSocket();
      final resolver = ConversationMediaLoaderResolver(
        cloudSocketService: socket,
        hardwareId: 'local-hardware',
        cache: cache,
      );

      await resolver.resolve('cloud-1').viewImage!.load(media: media, sessionId: 'session-1').bytes;
      final second = resolver.resolve('cloud-1').viewImage!.load(media: media, sessionId: 'session-1');
      expect(second.cachedBytes, isNotNull);
      expect(socket.fetches, ['cloud-1']);

      await resolver.resolve('cloud-2').viewImage!.load(media: media, sessionId: 'session-1').bytes;
      expect(socket.fetches, ['cloud-1', 'cloud-2']);
    });

    test('hosted attachment validation failures are not cached', () async {
      final cache = ConversationMediaByteCache(maximumBytes: 1024);
      final socket = _FakeSocket();
      final repository = HostedViewImageMediaRepository(socketService: socket, deviceId: 'cloud-1', cache: cache);
      final attachment = UserMessageAttachment.fromJson({
        'schemaVersion': 1,
        'id': 'image-1',
        'safeName': 'photo.png',
        'mimeType': 'image/png',
        'sizeBytes': _png.length,
        'sha256': 'b' * 64,
        'kind': 'image',
        'mediaId': 'media-image-1',
        'status': 'available',
      })!;
      await expectLater(repository.loadAttachment(attachment: attachment, sessionId: 's').bytes, throwsFormatException);
      expect(cache.length, 0);

      final valid = UserMessageAttachment.fromJson({
        'schemaVersion': 1,
        'id': 'image-1',
        'safeName': 'photo.png',
        'mimeType': 'image/png',
        'sizeBytes': _png.length,
        'sha256': sha256.convert(_png).toString(),
        'kind': 'image',
        'mediaId': 'media-image-1',
        'status': 'available',
      })!;
      await repository.loadAttachment(attachment: valid, sessionId: 's').bytes;
      expect(repository.loadAttachment(attachment: valid, sessionId: 's').cachedBytes, isNotNull);
      expect(socket.fetches.length, 2);
    });
  });

  testWidgets('returning to an image paints it on the first frame without a second request', (tester) async {
    var requests = 0;
    final repository = ViewImageMediaRepository(
      baseUrl: 'http://127.0.0.1:58184',
      hardwareId: 'hardware-1',
      headerProvider: () async => const {},
      cache: ConversationMediaByteCache(maximumBytes: 1024),
      clientFactory: () => MockClient((request) async {
        requests++;
        return http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'});
      }),
    );
    final event = CanonicalEvent(
      id: 'img',
      kind: EventKind.toolCall,
      status: EventStatus.done,
      sessionId: 'session-1',
      tool: {
        'name': 'view_image',
        'media': {
          'media_id': 'c' * 64,
          'name': 'view-image.png',
          'mime_type': 'image/png',
          'width': 1,
          'height': 1,
          'availability': 'available',
        },
      },
      timestamp: DateTime.utc(2026, 10, 21),
    );
    Widget card() => MaterialApp(home: Scaffold(body: ViewImageToolCard(event: event, loader: repository)));

    await tester.pumpWidget(card());
    for (var i = 0; i < 20 && find.byKey(const Key('view_image_thumbnail')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(find.byKey(const Key('view_image_thumbnail')), findsOneWidget);

    // Navigate away (dispose the card) and come back.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpWidget(card());

    expect(find.byKey(const Key('view_image_loading')), findsNothing, reason: 'no loading frame on return');
    expect(find.byKey(const Key('view_image_thumbnail')), findsOneWidget);
    expect(tester.widget<Image>(find.byType(Image)).gaplessPlayback, isTrue);
    expect(requests, 1);
  });
}

class _FakeSocket implements SanadSocketService {
  final List<String> fetches = [];

  @override
  Future<HostedConversationMedia> fetchHostedConversationMedia({
    required String deviceId,
    required String sessionId,
    required String mediaId,
    required String purpose,
    void Function(void Function())? registerCancel,
  }) async {
    fetches.add(deviceId);
    return HostedConversationMedia(bytes: _png, mimeType: 'image/png');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
