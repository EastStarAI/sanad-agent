import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:sanad_agent/infrastructure/stt/dictation_session.dart';
import 'package:sanad_agent/infrastructure/stt/hosted_dictation_channel.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

import 'support/fake_dictation_channel.dart';

/// D1: the local channel and the hosted relay are two framings of **one**
/// service. Driving the same script through both must produce the same ordered
/// event vocabulary and the same client-visible fields, because no downstream
/// (cubit, insertion, composer) may branch on connection scope.
void main() {
  late Directory home;
  late Directory modelDir;

  setUp(() {
    home = Directory.systemTemp.createTempSync('dictation-parity-');
    modelDir = Directory('${home.path}/manual-model')..createSync();
    File('${modelDir.path}/ggml-tiny.bin').writeAsBytesSync(const [1, 2, 3]);
    File('${home.path}/config.yaml').writeAsStringSync('''
stt:
  model_path: ${modelDir.path}
  model_idle_minutes: 0
''');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<void> until(bool Function() predicate, {required String reason}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!predicate()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $reason');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('a local and a hosted session emit the same ordered vocabulary',
      () async {
    // Local framing.
    final localEngine = FakeSttEngine();
    final localService = DictationService(
      sanadHome: home.path,
      platformSupported: true,
      engineFor: (_) => localEngine,
    );
    final local = FakeDictationChannel();
    final localRun = localService.handleChannel(local);
    await until(() => local.hasListener, reason: 'local service subscription');
    local.sendCommand(DictationCommand.start);
    await until(() => localEngine.started, reason: 'local engine start');
    localEngine.emit(const SttReadyEvent(loadMs: 100, modelId: 'test-model'));
    local.addAudio([1, 2, 3, 4]);
    // A frame and the control that ends the session are delivered on separate
    // stream turns, so the capture is awaited before the stop is issued; a real
    // client always sends `stop` after the last captured frame, never in the
    // same turn.
    await Future<void>.delayed(Duration.zero);
    local.sendCommand(DictationCommand.stop);
    await until(() => local.closed, reason: 'local channel closed');
    await localRun;

    // Hosted framing.
    final hostedEngine = FakeSttEngine();
    final hostedService = DictationService(
      sanadHome: home.path,
      platformSupported: true,
      engineFor: (_) => hostedEngine,
    );
    final hostedEvents = <(String, Map<String, dynamic>)>[];
    final hosted = HostedDictationChannel(
      dictationId: 'dict-1',
      requestId: 'dict-1',
      deviceId: 'device-1',
      emit: (event, payload) => hostedEvents.add((event, payload)),
    );
    final hostedRun = hostedService.handleChannel(hosted);
    hosted.beginSession();
    await until(() => hostedEngine.started, reason: 'hosted engine start');
    hostedEngine.emit(const SttReadyEvent(loadMs: 100, modelId: 'test-model'));
    hosted.onAudioFrame({
      'dictation_id': 'dict-1',
      'request_id': 'dict-1',
      'seq': 0,
      'data': const [1, 2, 3, 4],
    });
    await Future<void>.delayed(Duration.zero);
    hosted.onOrderedControl({
      'dictation_id': 'dict-1',
      'request_id': 'dict-1',
      'reason': 'stopped',
    });
    await until(() => hosted.isClosed, reason: 'hosted channel closed');
    await hostedRun;

    final localNames = [for (final entry in local.sent) entry.$1];
    final hostedNames = [for (final entry in hostedEvents) entry.$1];

    expect(hostedNames, localNames);
    expect(localNames, containsAllInOrder([
      'stt_status',
      'dictation_ready',
      'dictation_done',
    ]));
    expect(localEngine.audioLengths, [4]);
    expect(hostedEngine.audioLengths, [4]);

    // The same client-safe fields, not a second shape.
    final localReady = local.eventsOf('dictation_ready').single;
    final hostedReady = hostedEvents
        .firstWhere((entry) => entry.$1 == 'dictation_ready')
        .$2;
    expect(hostedReady['load_ms'], localReady['load_ms']);
    expect(hostedReady['model_id'], localReady['model_id']);
    // The hosted carrier stamps its own wire identity (`version`,
    // `dictation_id`) onto every payload; the transcript fields are the same
    // ones the local channel sends, not a second shape.
    final hostedDone = Map<String, dynamic>.from(
      hostedEvents.firstWhere((entry) => entry.$1 == 'dictation_done').$2,
    )..removeWhere((key, _) => key == 'version' || key == 'dictation_id');
    expect(hostedDone, local.eventsOf('dictation_done').single);
  });
}
