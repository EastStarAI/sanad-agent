import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/dictation/domain/hosted_dictation_transport.dart';
import 'package:socket_io_common/socket_io_common.dart';

import '../../helpers/fake_socket.dart';

/// Contract §6.2: a `dictation_audio` frame carries raw PCM16LE as a socket.io
/// **binary attachment**. The encoder decides that from the runtime type of
/// `data` (`hasBinary` → `is TypedData`), so a plain `List<int>` silently becomes
/// a JSON array of integers, which the Gateway refuses with `invalid_request`.
/// That is the defect this file pins, in both directions: the shape this
/// transport must produce, and the shape it must never produce again.
///
/// The field table and the sample frame live in
/// `test/fixtures/dictation/hosted_audio_frame.json`, which the hosted Gateway's
/// read-only mirror test asserts from its own copy.
const String _fixturePath = 'test/fixtures/dictation/hosted_audio_frame.json';

Map<String, dynamic> _loadFixture() => json.decode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;

/// The fixture stores samples as hex so the file stays diff-able; the transport
/// receives them as a deliberately plain [List] (the container a capture stream
/// may hand over, and the one that used to reach the wire untyped).
List<int> _samplesFrom(Map<String, dynamic> sample) {
  final hex = sample['data_hex'] as String;
  return [
    for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

List<Map<String, dynamic>> _fieldsOf(Map<String, dynamic> fixture) =>
    (fixture['fields'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic> _fieldNamed(Map<String, dynamic> fixture, String name) =>
    _fieldsOf(fixture).firstWhere((field) => field['name'] == name);

/// The wire type names the fixture's field table declares.
String _wireType(Object? value) {
  if (value is String) return 'string';
  if (value is int) return 'int';
  if (value is Uint8List) return 'bytes';
  return '${value.runtimeType}';
}

/// Exactly the packet `socket_io_client`'s `Socket.emit` builds before handing
/// it to the parser: `{'type': EVENT, 'data': [eventName, payload]}`.
Map<String, dynamic> _packetFor(String event, Map<String, dynamic> payload) => {
  'type': EVENT,
  'data': <dynamic>[event, payload],
  'options': const <String, dynamic>{'compress': false},
};

void main() {
  late FakeSanadSocketService socket;
  late Map<String, dynamic> fixture;
  late Map<String, dynamic> sample;

  setUp(() {
    socket = FakeSanadSocketService(hardwareId: 'this-mac')..setConnected(true);
    fixture = _loadFixture();
    sample = fixture['sample'] as Map<String, dynamic>;
  });

  tearDown(() {
    socket.dispose();
  });

  /// Opens a hosted transport carrying the fixture's own identity, sends the
  /// fixture's samples, and returns the emitted frame payload.
  Future<Map<String, dynamic>> emittedFrame() async {
    final transport = HostedDictationTransport.connect(
      socket: socket,
      deviceId: 'account-device-9',
      dictationId: sample['dictation_id'] as String,
      maxFrameBytes: 32768,
    );
    transport.sendAudio(_samplesFrom(sample));
    await transport.close();

    final frames = socket.capturedCommands.where((command) => command['event'] == fixture['event']).toList();
    expect(frames, hasLength(1), reason: 'one frame for one short slice');
    return Map<String, dynamic>.from(frames.single['data'] as Map);
  }

  test('the frame matches the shared field table with raw PCM bytes', () async {
    final frame = await emittedFrame();
    final bytes = _samplesFrom(sample);

    for (final field in _fieldsOf(fixture)) {
      final name = field['name'] as String;
      expect(frame.containsKey(name), isTrue, reason: '$name is contract');
      expect(
        _wireType(frame[name]),
        field['type'],
        reason: '$name is a ${field['type']} on the wire',
      );
    }

    expect(frame['version'], sample['version']);
    expect(
      frame['dictation_id'],
      matches(RegExp(_fieldNamed(fixture, 'dictation_id')['pattern'] as String)),
    );
    expect(frame['seq'], sample['seq']);
    expect(frame['seq'], greaterThanOrEqualTo(0));

    // The samples the transport received were a plain List<int>; the frame the
    // Gateway sees must still be a typed buffer holding exactly those bytes.
    expect(frame['data'], isA<Uint8List>());
    expect((frame['data'] as Uint8List).toList(), orderedEquals(bytes));
  });

  test('every split frame is a typed buffer, not only the first', () async {
    // "Always" is the claim under test: capture may hand over a plain list and
    // the transport splits it, so each emitted slice must be typed on its own.
    final bytes = [..._samplesFrom(sample), ..._samplesFrom(sample)];
    final transport = HostedDictationTransport.connect(
      socket: socket,
      deviceId: 'account-device-9',
      dictationId: sample['dictation_id'] as String,
      maxFrameBytes: 8,
    );
    transport.sendAudio(bytes);
    await transport.close();

    final frames = socket.capturedCommands
        .where((command) => command['event'] == fixture['event'])
        .map((command) => Map<String, dynamic>.from(command['data'] as Map))
        .toList();
    expect(frames, hasLength(2));
    expect([for (final frame in frames) frame['seq']], [0, 1]);
    for (var index = 0; index < frames.length; index++) {
      expect(frames[index]['data'], isA<Uint8List>());
      expect(
        (frames[index]['data'] as Uint8List).toList(),
        orderedEquals(bytes.sublist(index * 8, (index + 1) * 8)),
        reason: 'each frame carries its own slice, unchanged',
      );
    }
  });

  test('the real encoder emits one binary attachment of those bytes', () async {
    final frame = await emittedFrame();
    final bytes = _samplesFrom(sample);

    // Encode through the same parser the Client's socket uses, not a hand
    // rolled JSON comparison: only this proves what crosses the wire.
    final parts = Encoder().encode(_packetFor(fixture['event'] as String, frame)) as List;
    expect(parts, hasLength(2), reason: 'a JSON head plus one attachment');

    final head = parts.first as String;
    expect(
      // Wire head: packet type 5 (BINARY_EVENT), the attachment count, '-', JSON.
      head.startsWith('$BINARY_EVENT${parts.length - 1}-'),
      isTrue,
      reason: 'the packet must be a BINARY_EVENT with exactly one attachment',
    );
    expect(head, isNot(contains('"data":[')), reason: 'never an int array');
    expect(
      head,
      contains('"_placeholder":true'),
      reason: 'the payload carries a placeholder for the attachment',
    );

    final attachment = parts.last;
    expect(attachment, isA<TypedData>());
    expect(
      (attachment as List<int>).toList(),
      orderedEquals(bytes),
      reason: 'the attachment is the PCM16LE frame, byte for byte',
    );

    // The failure mode, kept executable so nobody reintroduces it: the same
    // frame with a plain int list encodes as JSON text and is refused.
    final plain =
        Encoder().encode(
              _packetFor(fixture['event'] as String, {
                ...frame,
                'data': bytes,
              }),
            )
            as List;
    expect(plain, hasLength(1));
    expect(plain.single, contains('"data":['));
  });
}
