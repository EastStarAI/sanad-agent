import 'dart:async';
import 'package:get_it/get_it.dart';
import 'package:test/test.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/infrastructure/voice/voice_transport_channel.dart';
import 'package:sanad_agent/infrastructure/voice/realtime_voice_provider.dart';
import 'package:sanad_agent/infrastructure/voice/voice_engine.dart';

class FakeVoiceTransportChannel extends VoiceTransportChannel {
  final audioController = StreamController<List<int>>.broadcast();
  final controlController = StreamController<String>.broadcast();
  final sentAudio = <List<int>>[];
  final sentControl = <Map<String, dynamic>>[];

  @override
  Stream<List<int>> get inputAudioStream => audioController.stream;

  @override
  Stream<String> get controlEvents => controlController.stream;

  @override
  void sendOutputAudio(List<int> pcmChunk) {
    sentAudio.add(pcmChunk);
  }

  @override
  void sendControlEvent(String eventName, Map<String, dynamic> payload) {
    sentControl.add({'event': eventName, 'payload': payload});
  }

  @override
  Future<void> close() async {
    await audioController.close();
    await controlController.close();
  }
}

class FakeRealtimeVoiceProvider extends RealtimeVoiceProvider {
  final eventController = StreamController<RealtimeVoiceEvent>.broadcast();
  final inputAudio = <List<int>>[];
  final controlEventsReceived = <String>[];
  bool connected = false;

  @override
  Stream<RealtimeVoiceEvent> get outputEvents => eventController.stream;

  @override
  Future<void> connect(Map<String, dynamic> sessionConfig) async {
    connected = true;
  }

  @override
  void handleInputAudio(List<int> pcmChunk16kHz) {
    inputAudio.add(pcmChunk16kHz);
  }

  @override
  void handleControlEvent(String eventName, Map<String, dynamic> payload) {
    controlEventsReceived.add(eventName);
  }

  @override
  Future<void> close() async {
    connected = false;
    await eventController.close();
  }
}

class FakeSessionManager implements SessionManager {
  final Map<String, List<Message>> dbMessages = {};

  @override
  List<Message> getMessages(
    String sessionId, {
    bool includeSuperseded = false,
  }) {
    return dbMessages.putIfAbsent(sessionId, () => []);
  }

  @override
  void saveSessionHistory(String sessionId, List<Message> messages) {
    dbMessages[sessionId] = List<Message>.from(messages);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return null;
  }
}

void main() {
  final getIt = GetIt.instance;
  late FakeVoiceTransportChannel channel;
  late FakeRealtimeVoiceProvider provider;
  late FakeSessionManager sessionManager;
  late VoiceEngine engine;
  final sessionId = 'test-voice-session';

  setUp(() {
    sessionManager = FakeSessionManager();
    getIt.registerSingleton<SessionManager>(sessionManager);

    channel = FakeVoiceTransportChannel();
    provider = FakeRealtimeVoiceProvider();
    engine = VoiceEngine(
      channel: channel,
      provider: provider,
      sessionId: sessionId,
    );
  });

  tearDown(() async {
    getIt.unregister<SessionManager>();
  });

  test('routes inputs from channel to provider', () async {
    await engine.start({});

    // Send audio from client
    final clientAudio = [1, 2, 3];
    channel.audioController.add(clientAudio);

    // Send control event from client
    channel.controlController.add('interrupt');

    // Wait a brief tick for async routing
    await Future.delayed(const Duration(milliseconds: 10));

    expect(provider.inputAudio.length, 1);
    expect(provider.inputAudio.first, clientAudio);
    expect(provider.controlEventsReceived.contains('interrupt'), true);

    await engine.close();
  });

  test('routes output events from provider to channel', () async {
    await engine.start({});

    // Simulate provider audio output
    final assistantAudio = [9, 8, 7];
    provider.eventController.add(AudioOutputEvent(assistantAudio));

    // Simulate provider transcription events
    provider.eventController.add(UserTranscriptionEvent('Hello'));
    provider.eventController.add(TextResponseEvent('Hi there'));

    // Wait a brief tick for async routing
    await Future.delayed(const Duration(milliseconds: 10));

    expect(channel.sentAudio.length, 1);
    expect(channel.sentAudio.first, assistantAudio);

    expect(
      channel.sentControl.any(
        (c) =>
            c['event'] == 'voice_user_transcription' &&
            c['payload']['text'] == 'Hello',
      ),
      true,
    );
    expect(
      channel.sentControl.any(
        (c) =>
            c['event'] == 'voice_text_response' &&
            c['payload']['text'] == 'Hi there',
      ),
      true,
    );

    await engine.close();
  });

  test(
    'flushes transcripts and saves user & assistant messages to database history',
    () async {
      await engine.start({});

      // User speaks, then assistant speaks (which flushes user turn)
      provider.eventController.add(UserTranscriptionEvent('Hello agent'));
      await Future.delayed(const Duration(milliseconds: 5));

      // Assistant starts speaking (flushes user turn 'Hello agent')
      provider.eventController.add(TextResponseEvent('Hello, how can I help?'));
      await Future.delayed(const Duration(milliseconds: 5));

      // Closing the engine flushes the remaining assistant turn 'Hello, how can I help?'
      await engine.close();

      final messages = sessionManager.getMessages(sessionId);
      expect(messages.length, 2);
      expect(messages[0].role, MessageRole.user);
      expect(messages[0].content, 'Hello agent');
      expect(messages[1].role, MessageRole.assistant);
      expect(messages[1].content, 'Hello, how can I help?');
    },
  );

  test(
    'saves assistant message as interrupted in DB on user interruption',
    () async {
      await engine.start({});

      provider.eventController.add(
        TextResponseEvent('I am running a very long computation'),
      );
      await Future.delayed(const Duration(milliseconds: 5));

      // User interrupts
      channel.controlController.add('interrupt');
      await Future.delayed(const Duration(milliseconds: 5));

      await engine.close();

      final messages = sessionManager.getMessages(sessionId);
      expect(messages.length, 1);
      expect(messages[0].role, MessageRole.assistant);
      expect(
        messages[0].content,
        'I am running a very long computation... [Interrupted]',
      );
    },
  );
}
