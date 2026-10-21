import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/screenshot_tool.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/models/view_image_media_metadata.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/infrastructure/platform/automation_service_interface.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/hosted_binary_relay.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:test/test.dart';

final class _FakeAutomationService implements AutomationServiceInterface {
  _FakeAutomationService({
    this.hasPermissions = true,
    List<int>? screenshotBytes,
  }) : screenshotBytes = screenshotBytes ?? _defaultPng();

  final bool hasPermissions;
  final List<int> screenshotBytes;

  static List<int> _defaultPng() {
    final image = img.Image(width: 64, height: 32, numChannels: 3);
    img.fill(image, color: img.ColorRgb8(255, 0, 0));
    return img.encodePng(image);
  }

  @override
  Future<bool> checkPermissions() async => hasPermissions;

  @override
  Future<bool> requestPermissions() async => hasPermissions;

  @override
  Future<List<int>> takeScreenshot() async => screenshotBytes;

  @override
  Future<void> simulateMouse({
    required String action,
    int? x,
    int? y,
    int? dx,
    int? dy,
  }) async {}

  @override
  Future<void> simulateKeyboard({
    required String action,
    String? text,
    List<String>? keys,
  }) async {}
}

final class _FakeRelaySocket implements io.Socket {
  final listeners = <String, List<Function>>{};
  final emitted = <(String, dynamic)>[];

  @override
  Function() on(String event, Function fn) {
    listeners.putIfAbsent(event, () => []).add(fn);
    return () {};
  }

  @override
  void emit(String event, [dynamic data]) => emitted.add((event, data));

  Future<void> receive(String event, dynamic data) async {
    for (final listener in listeners[event] ?? const <Function>[]) {
      final result = Function.apply(listener, [data]);
      if (result is Future) await result;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Uint8List _createImageBytes(String format, {int width = 32, int height = 16}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(10, 20, 30));
  return switch (format) {
    'png' => Uint8List.fromList(img.encodePng(image)),
    'jpeg' || 'jpg' => Uint8List.fromList(img.encodeJpg(image, quality: 80)),
    _ => throw ArgumentError('Unsupported format in test helper: $format'),
  };
}

ToolContext _context({
  RouteImageSupport imageSupport = RouteImageSupport.supported,
}) => ToolContext(
  sessionId: 'session-screenshot',
  toolCallId: 'call_screenshot',
  imageSupport: imageSupport,
);

/// Isolated capture destination so screenshot tests never write files into a
/// real user `Downloads` profile.
Directory _tempCaptureDir() {
  final dir = Directory.systemTemp.createTempSync('sanad-screenshot-save-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

ScreenshotTool _tool({
  required _FakeAutomationService service,
  Directory? captureDir,
}) => ScreenshotTool(
  automationService: service,
  screenshotDirectory: captureDir ?? _tempCaptureDir(),
);

void main() {
  group('ScreenshotTool', () {
    test(
      'executes and returns ToolImageBlock with the descriptive text preserved',
      () async {
        final expectedPng = _createImageBytes('png', width: 48, height: 24);
        final service = _FakeAutomationService(screenshotBytes: expectedPng);
        final captureDir = _tempCaptureDir();
        final tool = _tool(service: service, captureDir: captureDir);

        final result = await tool.executeResult(
          {'monitor_number': 1},
          context: _context(),
        );

        expect(result.isError, isFalse);
        expect(result.blocks, hasLength(2));
        expect(result.blocks[0], isA<ToolTextBlock>());
        expect(result.blocks[1], isA<ToolImageBlock>());

        final textBlock = result.blocks[0] as ToolTextBlock;
        expect(textBlock.text, contains('Screenshot taken successfully from monitor 1'));

        final imageBlock = result.blocks[1] as ToolImageBlock;
        expect(imageBlock.mimeType, 'image/png');
        expect(imageBlock.width, 48);
        expect(imageBlock.height, 24);
        expect(imageBlock.detail, ToolImageDetail.auto);
        expect(base64.decode(imageBlock.dataBase64), expectedPng);

        // The Downloads backup copy keeps the raw capture, independent of the
        // (possibly normalized) model attachment.
        final saved = captureDir.listSync().whereType<File>().toList();
        expect(saved, hasLength(1));
        expect(saved.single.path, endsWith('.jpg'));
        expect(saved.single.readAsBytesSync(), expectedPng);
        expect(textBlock.text, contains(saved.single.path));

        // execute() returns result.displayText
        final displayText = await tool.execute(
          {'monitor_number': 1},
          context: _context(),
        );
        expect(displayText, contains('Screenshot taken successfully from monitor 1'));
      },
    );

    test('supports JPEG screenshot format with correct dimensions and mime', () async {
      final expectedJpg = _createImageBytes('jpeg', width: 80, height: 40);
      final service = _FakeAutomationService(screenshotBytes: expectedJpg);
      final tool = _tool(service: service);

      final result = await tool.executeResult(
        {'monitor_number': 2},
        context: _context(),
      );

      expect(result.blocks, hasLength(2));
      final imageBlock = result.blocks[1] as ToolImageBlock;
      expect(imageBlock.mimeType, 'image/jpeg');
      expect(imageBlock.width, 80);
      expect(imageBlock.height, 40);
    });

    test('throws when permissions are missing', () async {
      final service = _FakeAutomationService(hasPermissions: false);
      final tool = _tool(service: service);

      expect(
        () => tool.executeResult({'monitor_number': 1}, context: _context()),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Missing Accessibility or Screen Recording permissions'),
          ),
        ),
      );
    });

    test(
      'keeps the capture text-only when the route cannot accept image input',
      () async {
        for (final unsupported in const [
          RouteImageSupport.unsupported,
          RouteImageSupport.unknown,
        ]) {
          final pngBytes = _createImageBytes('png', width: 48, height: 24);
          final service = _FakeAutomationService(screenshotBytes: pngBytes);
          final captureDir = _tempCaptureDir();
          final tool = _tool(service: service, captureDir: captureDir);

          final result = await tool.executeResult(
            {'monitor_number': 1},
            context: _context(imageSupport: unsupported),
          );

          expect(result.isError, isFalse);
          expect(result.blocks, hasLength(1));
          final textBlock = result.blocks.single as ToolTextBlock;
          expect(
            textBlock.text,
            contains('Screenshot taken successfully from monitor 1'),
          );
          expect(textBlock.text, contains('does not accept image input'));
          expect(
            captureDir.listSync().whereType<File>().toList(),
            hasLength(1),
            reason: 'the user-facing capture must be saved on every route',
          );
          expect(
            ViewImageMediaMetadata.project(
              sessionId: 'session-screenshot',
              toolName: 'system_screenshot',
              toolCallId: 'call_screenshot',
              result: result,
            ),
            isNull,
            reason: 'a text-only capture must not publish media metadata',
          );
        }
      },
    );

    test(
      'degrades to a text-only result when the capture is not a supported image',
      () async {
        final service = _FakeAutomationService(
          screenshotBytes: const [0x00, 0x01, 0x02, 0x03],
        );
        final captureDir = _tempCaptureDir();
        final tool = _tool(service: service, captureDir: captureDir);

        final result = await tool.executeResult(
          {'monitor_number': 1},
          context: _context(),
        );

        expect(result.isError, isFalse);
        expect(result.blocks, hasLength(1));
        expect(
          (result.blocks.single as ToolTextBlock).text,
          contains('image was not attached'),
        );
        expect(captureDir.listSync().whereType<File>().toList(), hasLength(1));
      },
    );

    test(
      'degrades to a text-only result when the capture exceeds the input limit',
      () async {
        final oversized = Uint8List(21 * 1024 * 1024);
        oversized.setAll(0, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
        final service = _FakeAutomationService(screenshotBytes: oversized);
        final captureDir = _tempCaptureDir();
        final tool = _tool(service: service, captureDir: captureDir);

        final result = await tool.executeResult(
          {'monitor_number': 1},
          context: _context(),
        );

        expect(result.isError, isFalse);
        expect(result.blocks, hasLength(1));
        expect(
          (result.blocks.single as ToolTextBlock).text,
          contains('20 MiB input limit'),
        );
      },
    );
  });

  group('ViewImageMediaMetadata.project for system_screenshot', () {
    test('projects system_screenshot as available with correct dimensions and mediaId', () {
      final pngBytes = _createImageBytes('png', width: 100, height: 50);
      final result = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'Screenshot taken successfully from monitor 1'),
          ToolImageBlock(
            dataBase64: base64.encode(pngBytes),
            mimeType: 'image/png',
            width: 100,
            height: 50,
            detail: ToolImageDetail.auto,
          ),
        ],
      );

      final metadata = ViewImageMediaMetadata.project(
        sessionId: 'session-xyz',
        toolName: 'system_screenshot',
        toolCallId: 'call_shot_1',
        result: result,
      );

      expect(metadata, isNotNull);
      expect(metadata!.availability, CanonicalMediaAvailability.available);
      expect(metadata.width, 100);
      expect(metadata.height, 50);
      expect(metadata.mimeType, 'image/png');
      expect(metadata.safeName, 'view-image.png');

      final expectedMediaId = sha256
          .convert(utf8.encode('session-xyz\u0000call_shot_1\u00001'))
          .toString();
      expect(metadata.mediaId, expectedMediaId);

      // Verify toPublicJson and fromPublicJson round-trip
      final json = metadata.toPublicJson();
      final roundTrip = ViewImageMediaMetadata.fromPublicJson(json);
      expect(roundTrip, isNotNull);
      expect(roundTrip!.mediaId, metadata.mediaId);
      expect(roundTrip.safeName, metadata.safeName);
      expect(roundTrip.mimeType, metadata.mimeType);
      expect(roundTrip.width, metadata.width);
      expect(roundTrip.height, metadata.height);
      expect(roundTrip.availability, CanonicalMediaAvailability.available);
    });

    test('rejects system_screenshot with error result or empty toolCallId', () {
      final pngBytes = _createImageBytes('png', width: 10, height: 10);
      final errorResult = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'Failed'),
          ToolImageBlock(
            dataBase64: base64.encode(pngBytes),
            mimeType: 'image/png',
            width: 10,
            height: 10,
            detail: ToolImageDetail.auto,
          ),
        ],
        isError: true,
      );

      expect(
        ViewImageMediaMetadata.project(
          sessionId: 'session-1',
          toolName: 'system_screenshot',
          toolCallId: 'call-1',
          result: errorResult,
        ),
        isNull,
      );

      expect(
        ViewImageMediaMetadata.project(
          sessionId: 'session-1',
          toolName: 'system_screenshot',
          toolCallId: '',
          result: ToolExecutionResult(
            blocks: [
              ToolTextBlock(text: 'OK'),
              ToolImageBlock(
                dataBase64: base64.encode(pngBytes),
                mimeType: 'image/png',
                width: 10,
                height: 10,
                detail: ToolImageDetail.auto,
              ),
            ],
          ),
        ),
        isNull,
      );
    });
  });

  group('ViewImageMediaProjection.resolve and HostedBinaryRelay for system_screenshot', () {
    test('ViewImageMediaProjection.resolve finds system_screenshot media by mediaId', () {
      final pngBytes = _createImageBytes('png', width: 64, height: 64);
      final toolResult = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'Screenshot taken'),
          ToolImageBlock(
            dataBase64: base64.encode(pngBytes),
            mimeType: 'image/png',
            width: 64,
            height: 64,
            detail: ToolImageDetail.auto,
          ),
        ],
      );

      final expectedMediaId = sha256
          .convert(utf8.encode('session-test\u0000call_shot_abc\u00001'))
          .toString();

      final history = [
        Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(
              id: 'call_shot_abc',
              name: 'system_screenshot',
              arguments: const {'monitor_number': 1},
            ),
          ],
        ),
        Message(
          role: MessageRole.tool,
          toolCallId: 'call_shot_abc',
          content: 'Screenshot taken',
          toolResult: toolResult,
        ),
      ];

      final resolved = ViewImageMediaProjection.resolve(
        sessionId: 'session-test',
        mediaId: expectedMediaId,
        messages: history,
      );

      expect(resolved, isNotNull);
      expect(resolved!.mediaId, expectedMediaId);
      expect(resolved.mimeType, 'image/png');
      expect(resolved.width, 64);
      expect(resolved.height, 64);
      expect(resolved.bytes, pngBytes);
    });

    test('HostedBinaryRelay resolves and streams system_screenshot media over socket', () async {
      final pngBytes = _createImageBytes('png', width: 32, height: 32);
      final toolResult = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'Screenshot taken'),
          ToolImageBlock(
            dataBase64: base64.encode(pngBytes),
            mimeType: 'image/png',
            width: 32,
            height: 32,
            detail: ToolImageDetail.auto,
          ),
        ],
      );

      final mediaId = sha256
          .convert(utf8.encode('session-relay\u0000call_relay_1\u00001'))
          .toString();

      final history = [
        Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(
              id: 'call_relay_1',
              name: 'system_screenshot',
              arguments: const {},
            ),
          ],
        ),
        Message(
          role: MessageRole.tool,
          toolCallId: 'call_relay_1',
          content: 'Screenshot taken',
          toolResult: toolResult,
        ),
      ];

      final tempDir = Directory.systemTemp.createTempSync('sanad-screenshot-test-');
      final db = AgentStateDatabase.inMemory();
      final store = AttachmentStore(db, stateHome: tempDir.path);
      addTearDown(() {
        db.dispose();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final socket = _FakeRelaySocket();
      final relay = HostedBinaryRelay(
        store: store,
        historyLoader: (sessionId) => sessionId == 'session-relay' ? history : const [],
      );
      relay.bind(socket);

      await socket.receive('conversation_media_fetch', {
        'version': 'v1',
        'route_id': 'route-shot-1',
        'session_id': 'session-relay',
        'media_id': mediaId,
      });

      expect(socket.emitted, isNotEmpty);
      expect(socket.emitted[0].$1, 'conversation_media_start');
      final startPayload = socket.emitted[0].$2 as Map<String, dynamic>;
      expect(startPayload['route_id'], 'route-shot-1');
      expect(startPayload['session_id'], 'session-relay');
      expect(startPayload['size_bytes'], pngBytes.length);
      expect(startPayload['mime_type'], 'image/png');
      expect(startPayload['sha256'], sha256.convert(pngBytes).toString());

      expect(socket.emitted[1].$1, 'conversation_media_chunk');
      final chunkPayload = socket.emitted[1].$2 as Map<String, dynamic>;
      expect(chunkPayload['route_id'], 'route-shot-1');
      expect(chunkPayload['index'], 0);
      expect(chunkPayload['data'], pngBytes);

      expect(socket.emitted[2].$1, 'conversation_media_complete');
      final completePayload = socket.emitted[2].$2 as Map<String, dynamic>;
      expect(completePayload['route_id'], 'route-shot-1');
    });
  });
}
