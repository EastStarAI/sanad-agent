import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/ollama_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/adapters/user_attachment_wire_discloser.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

void main() {
  final validPngBytes = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0A,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ];
  final validPdfBytes = utf8.encode('%PDF-1.4 sample content');
  final sampleHeicBytes = <int>[
    0x00,
    0x00,
    0x00,
    0x18,
    0x66,
    0x74,
    0x79,
    0x70,
    0x68,
    0x65,
    0x69,
    0x63,
  ];

  const fakeClientPath1 = '/Users/client/Downloads/quarterly_report.pdf';
  const fakeClientPath2 = r'C:\Users\client\Desktop\family_photo.heic';

  late Directory scratch;
  late AgentStateDatabase db;
  late AttachmentStore store;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('sanad-114f-test-');
    setSanadStateHomeOverride(scratch.path);
    setSanadHomeOverride(scratch.path);
    db = AgentStateDatabase.inMemory();
    store = AttachmentStore(db, stateHome: scratch.path);
  });

  tearDown(() {
    setSanadStateHomeOverride(null);
    setSanadHomeOverride(null);
    db.dispose();
    scratch.deleteSync(recursive: true);
  });

  UserAttachment createAttachment({
    required String id,
    required String safeName,
    required String mimeType,
    required List<int> bytes,
    required UserAttachmentKind kind,
  }) {
    final dir = Directory('${scratch.path}/attachments/$id')
      ..createSync(recursive: true);
    File('${dir.path}/payload').writeAsBytesSync(bytes);
    return UserAttachment(
      id: id,
      safeName: safeName,
      mimeType: mimeType,
      sizeBytes: bytes.length,
      sha256: sha256.convert(bytes).toString(),
      kind: kind,
      status: UserAttachmentStatus.available,
      agentLocalReference: 'attachments/$id/payload',
      mediaId: 'media-$id',
    );
  }

  group('UserAttachmentWireDiscloser Unit Tests', () {
    test('identifies provider-safe images vs files/unsafe image formats', () {
      final png = createAttachment(
        id: 'png-1',
        safeName: 'img.png',
        mimeType: 'image/png',
        bytes: validPngBytes,
        kind: UserAttachmentKind.image,
      );
      final jpeg = createAttachment(
        id: 'jpg-1',
        safeName: 'img.jpeg',
        mimeType: 'image/jpeg',
        bytes: [0xff, 0xd8, 0xff],
        kind: UserAttachmentKind.image,
      );
      final webp = createAttachment(
        id: 'webp-1',
        safeName: 'img.webp',
        mimeType: 'image/webp',
        bytes: [0x52, 0x49, 0x46, 0x46],
        kind: UserAttachmentKind.image,
      );
      final gif = createAttachment(
        id: 'gif-1',
        safeName: 'img.gif',
        mimeType: 'image/gif',
        bytes: [0x47, 0x49, 0x46, 0x38],
        kind: UserAttachmentKind.image,
      );
      final heic = createAttachment(
        id: 'heic-1',
        safeName: 'photo.heic',
        mimeType: 'image/heic',
        bytes: sampleHeicBytes,
        kind: UserAttachmentKind.image,
      );
      final svg = createAttachment(
        id: 'svg-1',
        safeName: 'vector.svg',
        mimeType: 'image/svg+xml',
        bytes: utf8.encode('<svg></svg>'),
        kind: UserAttachmentKind.image,
      );
      final pdf = createAttachment(
        id: 'pdf-1',
        safeName: 'report.pdf',
        mimeType: 'application/pdf',
        bytes: validPdfBytes,
        kind: UserAttachmentKind.file,
      );
      final jpgAlias = createAttachment(
        id: 'jpg-alias-1',
        safeName: 'alias.jpg',
        mimeType: 'image/jpg',
        bytes: [0xff, 0xd8, 0xff],
        kind: UserAttachmentKind.image,
      );

      expect(UserAttachmentWireDiscloser.isProviderSafeImage(png), isTrue);
      expect(UserAttachmentWireDiscloser.isProviderSafeImage(jpeg), isTrue);
      expect(UserAttachmentWireDiscloser.isProviderSafeImage(webp), isTrue);
      expect(UserAttachmentWireDiscloser.isProviderSafeImage(gif), isTrue);

      expect(UserAttachmentWireDiscloser.isProviderSafeImage(heic), isFalse);
      expect(UserAttachmentWireDiscloser.isProviderSafeImage(svg), isFalse);
      expect(UserAttachmentWireDiscloser.isProviderSafeImage(pdf), isFalse);
      expect(
        UserAttachmentWireDiscloser.isProviderSafeImage(jpgAlias),
        isFalse,
        reason: 'Only the four locked MIME types project as image parts.',
      );

      final partition = UserAttachmentWireDiscloser.partition([
        png,
        heic,
        pdf,
        jpeg,
        jpgAlias,
      ]);
      expect(partition.safeImages, equals([png, jpeg]));
      expect(partition.disclosedFiles, equals([heic, pdf, jpgAlias]));
    });

    test('sanitizes safe names and bounds length', () {
      expect(
        UserAttachmentWireDiscloser.sanitizeSafeName('report[final].pdf'),
        equals('report_final_.pdf'),
      );
      expect(
        UserAttachmentWireDiscloser.sanitizeSafeName('name\nwith\rbreaks.pdf'),
        equals('namewithbreaks.pdf'),
      );
      final veryLong = 'a' * 200 + '.txt';
      final sanitized = UserAttachmentWireDiscloser.sanitizeSafeName(veryLong);
      expect(sanitized.runes.length, lessThanOrEqualTo(120));
      expect(
        UserAttachmentWireDiscloser.sanitizeSafeName('a`b`.pdf'),
        equals('a_b_.pdf'),
        reason: 'Backticks must not open a code span inside the link label.',
      );
      expect(
        UserAttachmentWireDiscloser.sanitizeSafeName(
          'line\u2028sep\u2029x.pdf',
        ),
        equals('linesepx.pdf'),
        reason: 'Unicode line and paragraph separators are line breaks.',
      );
      expect(
        UserAttachmentWireDiscloser.sanitizeSafeName('\u0085neltest.pdf'),
        equals('neltest.pdf'),
        reason: 'C1 control runes are line breaks for many tokenizers.',
      );
    });

    test('formats reference lines with file URI and agent-side path', () {
      final pdf = createAttachment(
        id: 'pdf-ref-1',
        safeName: 'document.pdf',
        mimeType: 'application/pdf',
        bytes: validPdfBytes,
        kind: UserAttachmentKind.file,
      );
      final line = UserAttachmentWireDiscloser.formatReferenceLine(
        pdf,
        attachmentStore: store,
      );
      final expectedPath = p.normalize(
        '${scratch.path}/attachments/pdf-ref-1/payload',
      );
      expect(line, equals('[document.pdf](${Uri.file(expectedPath)})'));
      expect(line, startsWith('[document.pdf](file:///'));
      expect(line, isNot(contains(fakeClientPath1)));
    });

    test(
      'discloses content with reference lines and fixed guidance sentence',
      () {
        final pdf = createAttachment(
          id: 'pdf-disc-1',
          safeName: 'report.pdf',
          mimeType: 'application/pdf',
          bytes: validPdfBytes,
          kind: UserAttachmentKind.file,
        );
        final disclosed = UserAttachmentWireDiscloser.discloseContent(
          originalContent: 'Please summarize this document',
          nonSafeAttachments: [pdf],
          attachmentStore: store,
        );

        final expectedPath = p.normalize(
          '${scratch.path}/attachments/pdf-disc-1/payload',
        );
        expect(disclosed, startsWith('Please summarize this document\n\n'));
        expect(disclosed, contains('[report.pdf](${Uri.file(expectedPath)})'));
        expect(
          disclosed,
          contains(
            'Use your tools to read this file; it is available on disk.',
          ),
        );
        expect(disclosed, isNot(contains(fakeClientPath1)));
      },
    );
  });

  group('Wire Disclosure Path Safety', () {
    UserAttachment referenceAttachment({
      required String id,
      required String reference,
      String safeName = 'report.pdf',
      String mimeType = 'application/pdf',
      UserAttachmentKind kind = UserAttachmentKind.file,
      List<int>? bytes,
    }) {
      final payload = bytes ?? validPdfBytes;
      return UserAttachment(
        id: id,
        safeName: safeName,
        mimeType: mimeType,
        sizeBytes: payload.length,
        sha256: sha256.convert(payload).toString(),
        kind: kind,
        status: UserAttachmentStatus.available,
        agentLocalReference: reference,
        mediaId: 'media-$id',
      );
    }

    test('never echoes a foreign absolute client reference', () {
      final foreign = referenceAttachment(
        id: 'foreign-abs-1',
        reference: fakeClientPath1,
        safeName: 'quarterly_report.pdf',
      );

      final line = UserAttachmentWireDiscloser.formatReferenceLine(
        foreign,
        attachmentStore: store,
      );

      final expectedPath = p.normalize(
        '${scratch.path}/attachments/foreign-abs-1/payload',
      );
      expect(line, isNotNull);
      expect(line, isNot(contains('/Users/client')));
      expect(line, equals('[quarterly_report.pdf](${Uri.file(expectedPath)})'));
      final disclosed = UserAttachmentWireDiscloser.discloseContent(
        originalContent: 'Read the report',
        nonSafeAttachments: [foreign],
        attachmentStore: store,
      );
      expect(disclosed, isNot(contains(fakeClientPath1)));
    });

    test('never resolves a traversal reference outside the store jail', () {
      final traversal = referenceAttachment(
        id: 'traversal-1',
        reference: 'attachments/../../outside/payload',
        safeName: 'notes.pdf',
      );

      final line = UserAttachmentWireDiscloser.formatReferenceLine(
        traversal,
        attachmentStore: store,
      );

      final expectedPath = p.normalize(
        '${scratch.path}/attachments/traversal-1/payload',
      );
      expect(line, equals('[notes.pdf](${Uri.file(expectedPath)})'));
      expect(line, isNot(contains('outside')));
    });

    test(
      'unresolvable attachment id neither leaks a path nor orphans guidance',
      () {
        final unresolvable = referenceAttachment(
          id: '..',
          reference: 'attachments/../payload',
          safeName: 'escape.pdf',
        );

        expect(
          UserAttachmentWireDiscloser.formatReferenceLine(
            unresolvable,
            attachmentStore: store,
          ),
          isNull,
        );
        expect(
          UserAttachmentWireDiscloser.discloseContent(
            originalContent: 'Hello',
            nonSafeAttachments: [unresolvable],
            attachmentStore: store,
          ),
          equals('Hello'),
        );
      },
    );

    test('percent-encodes spaces and non-ASCII agent paths', () {
      final spacedHome = p.join(scratch.path, 'Sanad H\u00f6me', 'media');
      final spacedStore = AttachmentStore(db, stateHome: spacedHome);
      final attachment = referenceAttachment(
        id: 'space-1',
        reference: 'attachments/space-1/payload',
      );

      final line = UserAttachmentWireDiscloser.formatReferenceLine(
        attachment,
        attachmentStore: spacedStore,
      );
      final expectedPath = p.normalize(
        p.join(spacedHome, 'attachments/space-1/payload'),
      );

      expect(line, isNotNull);
      expect(line, isNot(contains(' ')));
      final destination = line!.substring(
        line.indexOf('](') + 2,
        line.length - 1,
      );
      expect(Uri.parse(destination).toFilePath(), equals(expectedPath));
      expect(line.contains(RegExp(r'[\r\n]')), isFalse);
    });

    test('missing payload bytes never break the wire reference build', () {
      final ghost = referenceAttachment(
        id: 'ghost-1',
        reference: 'attachments/ghost-1/payload',
      );

      final line = UserAttachmentWireDiscloser.formatReferenceLine(
        ghost,
        attachmentStore: store,
      );

      expect(line, isNotNull);
      expect(line, contains('ghost-1'));
    });
  });

  group('BaseOpenAIAdapter Wire Disclosure', () {
    late List<Map<String, dynamic>> requests;
    late BaseOpenAIAdapter adapter;

    setUp(() {
      requests = [];
      final catalog = {
        'opencode-go': {
          'api': 'https://opencode.ai/inference/go/v1',
          'models': {
            'gpt-4o': {
              'modalities': {
                'input': ['text', 'image'],
              },
            },
          },
        },
      };
      File(
        '${scratch.path}/catalog.json',
      ).writeAsStringSync(jsonEncode(catalog));

      adapter = BaseOpenAIAdapter(
        Config(environment: const {}),
        ProviderRegistry.findByNameOrAlias('opencode-go')!,
        defaultModelOverride: 'gpt-4o',
        apiKeyOverride: 'fixture-key',
        modelsDevService: ModelsDevService(
          cacheFilePathOverride: '${scratch.path}/catalog.json',
          client: MockClient(
            (_) async => http.Response(jsonEncode(catalog), 200),
          ),
        ),
        client: MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            '{"choices":[{"message":{"role":"assistant","content":"Done"},"finish_reason":"stop"}]}',
            200,
          );
        }),
      );
    });

    test(
      'non-image attachment -> reference line with agent-side path, guidance, no image_url part',
      () async {
        final pdf = createAttachment(
          id: 'openai-pdf-1',
          safeName: 'data.pdf',
          mimeType: 'application/pdf',
          bytes: validPdfBytes,
          kind: UserAttachmentKind.file,
        );

        final message = Message(
          role: MessageRole.user,
          content: 'Check the attached report',
          attachments: [pdf],
        );

        await adapter.generateResponse(
          [message],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final wireUserMsg = (requests.single['messages'] as List).firstWhere(
          (m) => m['role'] == 'user',
        );
        final rawPayload = jsonEncode(requests.single);

        final expectedPath = p.normalize(
          '${scratch.path}/attachments/openai-pdf-1/payload',
        );
        expect(wireUserMsg['content'], isA<String>());
        final contentStr = wireUserMsg['content'] as String;
        expect(contentStr, contains('[data.pdf](${Uri.file(expectedPath)})'));
        expect(
          contentStr,
          contains(UserAttachmentWireDiscloser.guidanceSentence),
        );
        expect(
          UserAttachmentWireDiscloser.guidanceSentence.allMatches(contentStr),
          hasLength(1),
        );
        expect(rawPayload, isNot(contains('"type":"image_url"')));
        expect(rawPayload, isNot(contains(fakeClientPath1)));
        expect(rawPayload, isNot(contains(fakeClientPath2)));
      },
    );

    test(
      'text-only route still discloses a non-image file reference',
      () async {
        final pdf = createAttachment(
          id: 'openai-text-pdf-1',
          safeName: 'invoice.pdf',
          mimeType: 'application/pdf',
          bytes: validPdfBytes,
          kind: UserAttachmentKind.file,
        );

        await adapter.generateResponse(
          [
            Message(
              role: MessageRole.user,
              content: 'Summarize the invoice',
              attachments: [pdf],
            ),
          ],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: false,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final rawPayload = jsonEncode(requests.single);
        final wireUserMsg = (requests.single['messages'] as List).firstWhere(
          (m) => m['role'] == 'user',
        );
        final expectedPath = p.normalize(
          '${scratch.path}/attachments/openai-text-pdf-1/payload',
        );

        expect(
          wireUserMsg['content'],
          contains('[invoice.pdf](${Uri.file(expectedPath)})'),
        );
        expect(
          wireUserMsg['content'],
          contains(UserAttachmentWireDiscloser.guidanceSentence),
        );
        expect(rawPayload, isNot(contains('image_url')));
        expect(rawPayload, isNot(contains(fakeClientPath1)));
      },
    );

    test(
      'foreign absolute attachment reference never reaches the HTTP body',
      () async {
        final foreign = UserAttachment(
          id: 'openai-foreign-1',
          safeName: 'payroll.pdf',
          mimeType: 'application/pdf',
          sizeBytes: validPdfBytes.length,
          sha256: sha256.convert(validPdfBytes).toString(),
          kind: UserAttachmentKind.file,
          status: UserAttachmentStatus.available,
          agentLocalReference: fakeClientPath1,
          mediaId: 'media-openai-foreign-1',
        );

        await adapter.generateResponse(
          [
            Message(
              role: MessageRole.user,
              content: 'Read payroll',
              attachments: [foreign],
            ),
          ],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final rawPayload = jsonEncode(requests.single);
        final wireUserMsg = (requests.single['messages'] as List).firstWhere(
          (m) => m['role'] == 'user',
        );
        final expectedPath = p.normalize(
          '${scratch.path}/attachments/openai-foreign-1/payload',
        );

        expect(rawPayload, isNot(contains('/Users/client')));
        expect(
          wireUserMsg['content'],
          contains('[payroll.pdf](${Uri.file(expectedPath)})'),
        );
      },
    );

    test('safe image -> image parts with base64, NO reference line', () async {
      final png = createAttachment(
        id: 'openai-png-1',
        safeName: 'chart.png',
        mimeType: 'image/png',
        bytes: validPngBytes,
        kind: UserAttachmentKind.image,
      );

      final message = Message(
        role: MessageRole.user,
        content: 'Inspect this image',
        attachments: [png],
      );

      await adapter.generateResponse(
        [message],
        options: LLMRequestOptions(
          attachmentStore: store,
          routeCapabilitySnapshot: const ModelCapabilityOverride(
            supportsImageInput: true,
          ),
        ),
      );

      expect(requests, hasLength(1));
      final wireUserMsg = (requests.single['messages'] as List).firstWhere(
        (m) => m['role'] == 'user',
      );
      final parts = wireUserMsg['content'] as List<dynamic>;

      expect(
        parts.any(
          (p) => p['type'] == 'text' && p['text'] == 'Inspect this image',
        ),
        isTrue,
      );
      final imagePart = parts.firstWhere((p) => p['type'] == 'image_url');
      expect(
        imagePart['image_url']['url'],
        startsWith('data:image/png;base64,'),
      );
      final rawPayload = jsonEncode(requests.single);
      expect(rawPayload, isNot(contains('file:///')));
      expect(
        rawPayload,
        isNot(contains(UserAttachmentWireDiscloser.guidanceSentence)),
      );
      expect(rawPayload, isNot(contains(fakeClientPath1)));
    });

    test(
      'unsafe image MIME (HEIC) -> reference line, NEVER an image_url part',
      () async {
        final heic = createAttachment(
          id: 'openai-heic-1',
          safeName: 'photo.heic',
          mimeType: 'image/heic',
          bytes: sampleHeicBytes,
          kind: UserAttachmentKind.image,
        );

        final message = Message(
          role: MessageRole.user,
          content: 'Look at my photo',
          attachments: [heic],
        );

        await adapter.generateResponse(
          [message],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final wireUserMsg = (requests.single['messages'] as List).firstWhere(
          (m) => m['role'] == 'user',
        );
        final rawPayload = jsonEncode(requests.single);

        final expectedPath = p.normalize(
          '${scratch.path}/attachments/openai-heic-1/payload',
        );
        expect(wireUserMsg['content'], isA<String>());
        final contentStr = wireUserMsg['content'] as String;
        expect(contentStr, contains('[photo.heic](${Uri.file(expectedPath)})'));
        expect(
          contentStr,
          contains(UserAttachmentWireDiscloser.guidanceSentence),
        );
        expect(
          UserAttachmentWireDiscloser.guidanceSentence.allMatches(contentStr),
          hasLength(1),
        );
        expect(rawPayload, isNot(contains('"type":"image_url"')));
        expect(rawPayload, isNot(contains(fakeClientPath1)));
        expect(rawPayload, isNot(contains(fakeClientPath2)));
      },
    );

    test(
      'mixed safe image + non-image -> safe image part + file reference in text part',
      () async {
        final png = createAttachment(
          id: 'openai-mix-png',
          safeName: 'diagram.png',
          mimeType: 'image/png',
          bytes: validPngBytes,
          kind: UserAttachmentKind.image,
        );
        final pdf = createAttachment(
          id: 'openai-mix-pdf',
          safeName: 'specs.pdf',
          mimeType: 'application/pdf',
          bytes: validPdfBytes,
          kind: UserAttachmentKind.file,
        );

        final message = Message(
          role: MessageRole.user,
          content: 'Review both files',
          attachments: [png, pdf],
        );

        await adapter.generateResponse(
          [message],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final wireUserMsg = (requests.single['messages'] as List).firstWhere(
          (m) => m['role'] == 'user',
        );
        final parts = wireUserMsg['content'] as List<dynamic>;

        final textPart = parts.firstWhere((p) => p['type'] == 'text');
        final text = textPart['text'] as String;
        final expectedPdfPath = p.normalize(
          '${scratch.path}/attachments/openai-mix-pdf/payload',
        );
        expect(text, contains('Review both files'));
        expect(text, contains('[specs.pdf](${Uri.file(expectedPdfPath)})'));
        expect(text, contains(UserAttachmentWireDiscloser.guidanceSentence));
        expect(
          UserAttachmentWireDiscloser.guidanceSentence.allMatches(text),
          hasLength(1),
        );
        expect(text, isNot(contains('diagram.png')));

        final imagePart = parts.firstWhere((p) => p['type'] == 'image_url');
        expect(
          imagePart['image_url']['url'],
          startsWith('data:image/png;base64,'),
        );
      },
    );
  });

  group('BaseAnthropicAdapter Wire Disclosure', () {
    late List<Map<String, dynamic>> requests;
    late BaseAnthropicAdapter adapter;

    setUp(() {
      requests = [];
      adapter = BaseAnthropicAdapter(
        Config(environment: const {}),
        ProviderRegistry.findByNameOrAlias('anthropic')!,
        defaultModelOverride: 'claude-3-5-sonnet-20241022',
        apiKeyOverride: 'fixture-key',
        client: MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'id': 'msg_1',
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'Received'},
              ],
              'model': 'claude-3-5-sonnet-20241022',
              'stop_reason': 'end_turn',
              'usage': {'input_tokens': 10, 'output_tokens': 5},
            }),
            200,
          );
        }),
      );
    });

    test(
      'non-image attachment -> reference line in user content, no image block',
      () async {
        final pdf = createAttachment(
          id: 'ant-pdf-1',
          safeName: 'contract.pdf',
          mimeType: 'application/pdf',
          bytes: validPdfBytes,
          kind: UserAttachmentKind.file,
        );

        final message = Message(
          role: MessageRole.user,
          content: 'Read this contract',
          attachments: [pdf],
        );

        await adapter.generateResponse(
          [message],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final wireUserMsg = (requests.single['messages'] as List).firstWhere(
          (m) => m['role'] == 'user',
        );
        final rawPayload = jsonEncode(requests.single);

        final expectedPath = p.normalize(
          '${scratch.path}/attachments/ant-pdf-1/payload',
        );
        final contentStr = wireUserMsg['content'] as String;
        expect(
          contentStr,
          contains('[contract.pdf](${Uri.file(expectedPath)})'),
        );
        expect(
          contentStr,
          contains(UserAttachmentWireDiscloser.guidanceSentence),
        );
        expect(
          UserAttachmentWireDiscloser.guidanceSentence.allMatches(contentStr),
          hasLength(1),
        );
        expect(rawPayload, isNot(contains('"type":"image"')));
        expect(rawPayload, isNot(contains(fakeClientPath1)));
      },
    );

    test('safe image -> image block with base64, NO reference line', () async {
      final png = createAttachment(
        id: 'ant-png-1',
        safeName: 'screenshot.png',
        mimeType: 'image/png',
        bytes: validPngBytes,
        kind: UserAttachmentKind.image,
      );

      final message = Message(
        role: MessageRole.user,
        content: 'Describe the screenshot',
        attachments: [png],
      );

      await adapter.generateResponse(
        [message],
        options: LLMRequestOptions(
          attachmentStore: store,
          routeCapabilitySnapshot: const ModelCapabilityOverride(
            supportsImageInput: true,
          ),
        ),
      );

      expect(requests, hasLength(1));
      final wireUserMsg = (requests.single['messages'] as List).firstWhere(
        (m) => m['role'] == 'user',
      );
      final parts = wireUserMsg['content'] as List<dynamic>;

      expect(
        parts.any(
          (p) => p['type'] == 'text' && p['text'] == 'Describe the screenshot',
        ),
        isTrue,
      );
      final imagePart = parts.firstWhere((p) => p['type'] == 'image');
      expect(imagePart['source']['type'], 'base64');
      expect(imagePart['source']['media_type'], 'image/png');
      final rawPayload = jsonEncode(requests.single);
      expect(rawPayload, isNot(contains('file:///')));
      expect(
        rawPayload,
        isNot(contains(UserAttachmentWireDiscloser.guidanceSentence)),
      );
    });

    test(
      'unsafe image MIME (HEIC) -> reference line, NEVER an image block',
      () async {
        final heic = createAttachment(
          id: 'ant-heic-1',
          safeName: 'photo.heic',
          mimeType: 'image/heic',
          bytes: sampleHeicBytes,
          kind: UserAttachmentKind.image,
        );

        final message = Message(
          role: MessageRole.user,
          content: 'Check this heic file',
          attachments: [heic],
        );

        await adapter.generateResponse(
          [message],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final wireUserMsg = (requests.single['messages'] as List).firstWhere(
          (m) => m['role'] == 'user',
        );
        final rawPayload = jsonEncode(requests.single);

        final expectedPath = p.normalize(
          '${scratch.path}/attachments/ant-heic-1/payload',
        );
        final contentStr = wireUserMsg['content'] as String;
        expect(contentStr, contains('[photo.heic](${Uri.file(expectedPath)})'));
        expect(
          contentStr,
          contains(UserAttachmentWireDiscloser.guidanceSentence),
        );
        expect(
          UserAttachmentWireDiscloser.guidanceSentence.allMatches(contentStr),
          hasLength(1),
        );
        expect(rawPayload, isNot(contains('"type":"image"')));
        expect(rawPayload, isNot(contains(fakeClientPath1)));
      },
    );
  });

  group('CodexResponsesAdapter / CodexResponsesCodec Wire Disclosure', () {
    late List<Map<String, dynamic>> requests;
    late CodexResponsesAdapter adapter;

    setUp(() {
      requests = [];
      adapter = CodexResponsesAdapter(
        Config(environment: const {}),
        ProviderRegistry.findByNameOrAlias('openai-codex')!,
        defaultModelOverride: 'o1',
        apiKeyOverride: 'fixture-key',
        client: MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            'data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Done"}]}]}}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
    });

    test(
      'non-image attachment -> reference line in input_text, NO input_image',
      () async {
        final pdf = createAttachment(
          id: 'codex-pdf-1',
          safeName: 'whitepaper.pdf',
          mimeType: 'application/pdf',
          bytes: validPdfBytes,
          kind: UserAttachmentKind.file,
        );

        final message = Message(
          role: MessageRole.user,
          content: 'Summarize the whitepaper',
          attachments: [pdf],
        );

        await adapter.generateResponse(
          [message],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final input = requests.single['input'] as List<dynamic>;
        final userItem = input.firstWhere((item) => item['role'] == 'user');
        final content = userItem['content'] as List<dynamic>;
        final rawPayload = jsonEncode(requests.single);

        final expectedPath = p.normalize(
          '${scratch.path}/attachments/codex-pdf-1/payload',
        );
        final textItem = content.firstWhere((p) => p['type'] == 'input_text');
        expect(
          textItem['text'],
          contains('[whitepaper.pdf](${Uri.file(expectedPath)})'),
        );
        expect(
          textItem['text'],
          contains(UserAttachmentWireDiscloser.guidanceSentence),
        );
        expect(rawPayload, isNot(contains('"type":"input_image"')));
        expect(rawPayload, isNot(contains(fakeClientPath1)));
      },
    );

    test(
      'safe image -> input_image with base64, NO reference line in input_text',
      () async {
        final png = createAttachment(
          id: 'codex-png-1',
          safeName: 'ui.png',
          mimeType: 'image/png',
          bytes: validPngBytes,
          kind: UserAttachmentKind.image,
        );

        final message = Message(
          role: MessageRole.user,
          content: 'Review UI mock',
          attachments: [png],
        );

        await adapter.generateResponse(
          [message],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final input = requests.single['input'] as List<dynamic>;
        final userItem = input.firstWhere((item) => item['role'] == 'user');
        final content = userItem['content'] as List<dynamic>;
        final rawPayload = jsonEncode(requests.single);

        final textItem = content.firstWhere((p) => p['type'] == 'input_text');
        expect(textItem['text'], 'Review UI mock');
        final imageItem = content.firstWhere((p) => p['type'] == 'input_image');
        expect(imageItem['image_url'], startsWith('data:image/png;base64,'));
        expect(rawPayload, isNot(contains('file:///')));
        expect(
          rawPayload,
          isNot(contains(UserAttachmentWireDiscloser.guidanceSentence)),
        );
      },
    );

    test(
      'unsafe image MIME (HEIC) -> reference line in input_text, NEVER an input_image',
      () async {
        final heic = createAttachment(
          id: 'codex-heic-1',
          safeName: 'landscape.heic',
          mimeType: 'image/heic',
          bytes: sampleHeicBytes,
          kind: UserAttachmentKind.image,
        );

        final message = Message(
          role: MessageRole.user,
          content: 'Analyze photo',
          attachments: [heic],
        );

        await adapter.generateResponse(
          [message],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final input = requests.single['input'] as List<dynamic>;
        final userItem = input.firstWhere((item) => item['role'] == 'user');
        final content = userItem['content'] as List<dynamic>;
        final rawPayload = jsonEncode(requests.single);

        final expectedPath = p.normalize(
          '${scratch.path}/attachments/codex-heic-1/payload',
        );
        final textItem = content.firstWhere((p) => p['type'] == 'input_text');
        expect(
          textItem['text'],
          contains('[landscape.heic](${Uri.file(expectedPath)})'),
        );
        expect(
          textItem['text'],
          contains(UserAttachmentWireDiscloser.guidanceSentence),
        );
        expect(rawPayload, isNot(contains('"type":"input_image"')));
        expect(rawPayload, isNot(contains(fakeClientPath1)));
      },
    );
  });

  group('OllamaAdapter Wire Disclosure', () {
    late List<Map<String, dynamic>> requests;
    late OllamaAdapter adapter;

    setUp(() {
      requests = [];
      adapter = OllamaAdapter(
        Config(environment: const {}),
        ProviderRegistry.findByNameOrAlias('ollama')!,
        defaultModelOverride: 'llava:latest',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/api/show')) {
            return http.Response(
              jsonEncode({
                'details': {'family': 'llama'},
                'model_info': {'general.architecture': 'llama'},
                'ollama_capabilities': ['vision'],
              }),
              200,
            );
          }
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'model': 'llava:latest',
              'message': {'role': 'assistant', 'content': 'Understood'},
              'done': true,
              'done_reason': 'stop',
            }),
            200,
          );
        }),
      );
    });

    test(
      'non-image attachment -> reference line in message content, NO images array',
      () async {
        final pdf = createAttachment(
          id: 'ollama-pdf-1',
          safeName: 'notes.pdf',
          mimeType: 'application/pdf',
          bytes: validPdfBytes,
          kind: UserAttachmentKind.file,
        );

        final message = Message(
          role: MessageRole.user,
          content: 'Review notes',
          attachments: [pdf],
        );

        await adapter.generateResponse(
          [message],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final wireUserMsg = (requests.single['messages'] as List).firstWhere(
          (m) => m['role'] == 'user',
        );
        final rawPayload = jsonEncode(requests.single);

        final expectedPath = p.normalize(
          '${scratch.path}/attachments/ollama-pdf-1/payload',
        );
        final contentStr = wireUserMsg['content'] as String;
        expect(contentStr, contains('[notes.pdf](${Uri.file(expectedPath)})'));
        expect(
          contentStr,
          contains(UserAttachmentWireDiscloser.guidanceSentence),
        );
        expect(
          UserAttachmentWireDiscloser.guidanceSentence.allMatches(contentStr),
          hasLength(1),
        );
        expect(wireUserMsg['images'], isNull);
        expect(rawPayload, isNot(contains(fakeClientPath1)));
      },
    );

    test(
      'safe image -> base64 in images array, NO reference line in content',
      () async {
        final png = createAttachment(
          id: 'ollama-png-1',
          safeName: 'drawing.png',
          mimeType: 'image/png',
          bytes: validPngBytes,
          kind: UserAttachmentKind.image,
        );

        final message = Message(
          role: MessageRole.user,
          content: 'Describe drawing',
          attachments: [png],
        );

        await adapter.generateResponse(
          [message],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final wireUserMsg = (requests.single['messages'] as List).firstWhere(
          (m) => m['role'] == 'user',
        );
        final rawPayload = jsonEncode(requests.single);

        expect(wireUserMsg['content'], 'Describe drawing');
        expect(wireUserMsg['images'], isA<List>());
        expect(
          (wireUserMsg['images'] as List).single,
          equals(base64Encode(validPngBytes)),
        );
        expect(rawPayload, isNot(contains('file:///')));
        expect(
          rawPayload,
          isNot(contains(UserAttachmentWireDiscloser.guidanceSentence)),
        );
      },
    );

    test(
      'unsafe image MIME (HEIC) -> reference line in content, NEVER in images array',
      () async {
        final heic = createAttachment(
          id: 'ollama-heic-1',
          safeName: 'pic.heic',
          mimeType: 'image/heic',
          bytes: sampleHeicBytes,
          kind: UserAttachmentKind.image,
        );

        final message = Message(
          role: MessageRole.user,
          content: 'Inspect pic',
          attachments: [heic],
        );

        await adapter.generateResponse(
          [message],
          options: LLMRequestOptions(
            attachmentStore: store,
            routeCapabilitySnapshot: const ModelCapabilityOverride(
              supportsImageInput: true,
            ),
          ),
        );

        expect(requests, hasLength(1));
        final wireUserMsg = (requests.single['messages'] as List).firstWhere(
          (m) => m['role'] == 'user',
        );
        final rawPayload = jsonEncode(requests.single);

        final expectedPath = p.normalize(
          '${scratch.path}/attachments/ollama-heic-1/payload',
        );
        final contentStr = wireUserMsg['content'] as String;
        expect(contentStr, contains('[pic.heic](${Uri.file(expectedPath)})'));
        expect(
          contentStr,
          contains(UserAttachmentWireDiscloser.guidanceSentence),
        );
        expect(
          UserAttachmentWireDiscloser.guidanceSentence.allMatches(contentStr),
          hasLength(1),
        );
        expect(wireUserMsg['images'], isNull);
        expect(rawPayload, isNot(contains(fakeClientPath1)));
      },
    );
  });
}
