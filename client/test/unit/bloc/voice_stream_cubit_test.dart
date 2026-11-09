import 'dart:async';
import 'dart:typed_data';

import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/voice/domain/services/voice_stream_service.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_socket.dart';

class FakeVoiceStreamService extends Fake implements VoiceStreamService {
  final StreamController<List<int>> recorderController = StreamController<List<int>>.broadcast();
  bool startPlaybackCalled = false;
  bool startRecordingCalled = false;
  bool stopRecordingCalled = false;
  bool stopPlaybackCalled = false;
  final playedChunks = <List<int>>[];

  @override
  void playAudioChunk(List<int> pcmChunk) {
    playedChunks.add(pcmChunk);
  }

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<List<int>>> startRecording() async {
    startRecordingCalled = true;
    return recorderController.stream;
  }

  @override
  Future<void> stopRecording() async {
    stopRecordingCalled = true;
  }

  @override
  Future<void> startPlayback() async {
    startPlaybackCalled = true;
  }

  @override
  Future<void> stopPlayback() async {
    stopPlaybackCalled = true;
  }
}

List<int> makePcmChunk({required int sampleValue, int count = 100}) {
  final builder = BytesBuilder();
  final data = ByteData(2);
  for (int i = 0; i < count; i++) {
    data.setInt16(0, sampleValue, Endian.little);
    builder.add(data.buffer.asUint8List());
  }
  return builder.toBytes();
}

void main() {
  late FakeVoiceStreamService voiceService;
  late FakeSanadSocketService cloudSocket;
  late DeviceConnectionCoordinator coordinator;
  late VoiceStreamCubit cubit;

  setUp(() {
    voiceService = FakeVoiceStreamService();
    cloudSocket = FakeSanadSocketService();
    cloudSocket.setConnected(true);

    coordinator = createTestResolver(
      cloudSocket: cloudSocket,
      localSocket: FakeSanadSocketService()..setConnected(false), // Disable local connection
    );

    cubit = VoiceStreamCubit(voiceStreamService: voiceService, connectionCoordinator: coordinator);
  });

  tearDown(() async {
    await cubit.close();
    coordinator.dispose();
    cloudSocket.dispose();
  });

  test('buffers quiet chunks and sends them with the lookahead buffer once voice is detected', () async {
    final agent = DeviceConfig(id: 'test-agent-id', name: 'Test Agent', isOnline: true);

    await cubit.startVoiceSession(agent: agent, sessionId: 'test-session');

    // Make chunks
    final quietChunk1 = makePcmChunk(sampleValue: 10, count: 50);
    final quietChunk2 = makePcmChunk(sampleValue: 20, count: 50);
    final loudChunk = makePcmChunk(sampleValue: 1000, count: 50);

    // 1. Send quietChunk1
    voiceService.recorderController.add(quietChunk1);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Verify nothing sent to socket yet
    expect(cloudSocket.capturedCommands.where((c) => c['event'] == 'voice_audio_chunk'), isEmpty);

    // 2. Send quietChunk2
    voiceService.recorderController.add(quietChunk2);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Verify still nothing sent to socket
    expect(cloudSocket.capturedCommands.where((c) => c['event'] == 'voice_audio_chunk'), isEmpty);

    // 3. Send loudChunk
    voiceService.recorderController.add(loudChunk);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Verify all chunks (quietChunk1, quietChunk2, and loudChunk) are now sent in order
    final sentCommands = cloudSocket.capturedCommands.where((c) => c['event'] == 'voice_audio_chunk').toList();

    expect(sentCommands.length, equals(3));
    expect(sentCommands[0]['data']['data'], equals(quietChunk1));
    expect(sentCommands[1]['data']['data'], equals(quietChunk2));
    expect(sentCommands[2]['data']['data'], equals(loudChunk));
  });

  test('relayed audio without identity is never played', () async {
    final agent = DeviceConfig(id: 'test-agent-id', name: 'Test Agent', isOnline: true);
    await cubit.startVoiceSession(agent: agent, sessionId: 'own-session');

    cloudSocket.debugEmitEvent({
      'type': 'voice_audio_chunk_relay',
      'data': makePcmChunk(sampleValue: 900, count: 20),
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(voiceService.playedChunks, isEmpty);
  });

  test('relayed audio from another session is never played', () async {
    final agent = DeviceConfig(id: 'test-agent-id', name: 'Test Agent', isOnline: true);
    await cubit.startVoiceSession(agent: agent, sessionId: 'own-session');

    cloudSocket.debugEmitEvent({
      'type': 'voice_audio_chunk_relay',
      'session_id': 'other-session',
      'request_id': 'other-session',
      'data': makePcmChunk(sampleValue: 900, count: 20),
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(voiceService.playedChunks, isEmpty);
  });

  test('relayed audio with a mismatched request id is never played', () async {
    final agent = DeviceConfig(id: 'test-agent-id', name: 'Test Agent', isOnline: true);
    await cubit.startVoiceSession(agent: agent, sessionId: 'own-session');

    cloudSocket.debugEmitEvent({
      'type': 'voice_audio_chunk_relay',
      'session_id': 'own-session',
      'request_id': 'a-different-request',
      'data': makePcmChunk(sampleValue: 900, count: 20),
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(voiceService.playedChunks, isEmpty);
  });

  test('relayed audio with a foreign device id is never played', () async {
    final agent = DeviceConfig(id: 'test-agent-id', name: 'Test Agent', isOnline: true);
    await cubit.startVoiceSession(agent: agent, sessionId: 'own-session');

    cloudSocket.debugEmitEvent({
      'type': 'voice_audio_chunk_relay',
      'device_id': 'someone-else',
      'session_id': 'own-session',
      'request_id': 'own-session',
      'data': makePcmChunk(sampleValue: 900, count: 20),
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(voiceService.playedChunks, isEmpty);
  });

  test('relayed audio from this exact session is played', () async {
    final agent = DeviceConfig(id: 'test-agent-id', name: 'Test Agent', isOnline: true);
    await cubit.startVoiceSession(agent: agent, sessionId: 'own-session');
    final chunk = makePcmChunk(sampleValue: 900, count: 20);

    cloudSocket.debugEmitEvent({
      'type': 'voice_audio_chunk_relay',
      'session_id': 'own-session',
      'request_id': 'own-session',
      'data': chunk,
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(voiceService.playedChunks, [chunk]);
  });

  test('sends quiet chunks during hangover period and then stops sending when hangover expires', () async {
    final agent = DeviceConfig(id: 'test-agent-id', name: 'Test Agent', isOnline: true);

    await cubit.startVoiceSession(agent: agent, sessionId: 'test-session');

    final loudChunk = makePcmChunk(sampleValue: 1000, count: 50);
    final quietChunk = makePcmChunk(sampleValue: 10, count: 50);

    // 1. Trigger speech
    voiceService.recorderController.add(loudChunk);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    cloudSocket.clearCaptured();

    // 2. Send quiet chunk immediately (within hangover)
    voiceService.recorderController.add(quietChunk);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Quiet chunk should be sent because hangover timer is active
    var sent = cloudSocket.capturedCommands.where((c) => c['event'] == 'voice_audio_chunk').toList();
    expect(sent.length, equals(1));
    expect(sent[0]['data']['data'], equals(quietChunk));
    cloudSocket.clearCaptured();

    // 3. Wait for hangover to expire (> 800ms)
    await Future<void>.delayed(const Duration(milliseconds: 850));

    // 4. Send another quiet chunk
    voiceService.recorderController.add(quietChunk);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Quiet chunk should be filtered out / not sent
    sent = cloudSocket.capturedCommands.where((c) => c['event'] == 'voice_audio_chunk').toList();
    expect(sent, isEmpty);
  });

  test('does not send any audio chunks when muted', () async {
    final agent = DeviceConfig(id: 'test-agent-id', name: 'Test Agent', isOnline: true);

    await cubit.startVoiceSession(agent: agent, sessionId: 'test-session');

    // Mute microphone
    cubit.toggleMute();
    expect(cubit.state.isMuted, isTrue);

    // Send a loud chunk
    final loudChunk = makePcmChunk(sampleValue: 1000, count: 50);
    voiceService.recorderController.add(loudChunk);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Verify nothing sent to socket because it was muted
    expect(cloudSocket.capturedCommands.where((c) => c['event'] == 'voice_audio_chunk'), isEmpty);

    // Unmute microphone
    cubit.toggleMute();
    expect(cubit.state.isMuted, isFalse);

    // Send loud chunk again
    voiceService.recorderController.add(loudChunk);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Now it should send
    final sentCommands = cloudSocket.capturedCommands.where((c) => c['event'] == 'voice_audio_chunk').toList();
    expect(sentCommands.length, equals(1));
    expect(sentCommands[0]['data']['data'], equals(loudChunk));
  });
}
