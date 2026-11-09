import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:sanad_agent/infrastructure/stt/dictation_session.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';

import 'support/fake_dictation_channel.dart';
import 'package:test/test.dart';

/// Bounded wait for an asynchronous connection state change.
Future<void> until(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory home;
  late Directory modelDir;

  setUp(() {
    home = Directory.systemTemp.createTempSync('dictation-connection-');
    // A whisper path override needs no native shim: the injected engine factory
    // provides the recognizer, so the real lease/start/teardown path runs.
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

  /// A service whose every session uses [engine].
  DictationService serviceWithEngine(FakeSttEngine engine) => DictationService(
    sanadHome: home.path,
    platformSupported: true,
    engineFor: (_) => engine,
    whisperRuntimeAvailable: () => true,
  );

  group('owned dictation lease', () {
    test('a peer token never releases the owner lease', () {
      final service = serviceWithEngine(FakeSttEngine());
      final owner = Object();
      final peer = Object();

      expect(service.acquireSession(owner), isTrue);
      expect(service.isBusy, isTrue);

      service.releaseSession(peer);
      expect(
        service.isBusy,
        isTrue,
        reason: 'a status-only channel must not free a live session',
      );
      expect(service.acquireSession(peer), isFalse);

      service.releaseSession(owner);
      expect(service.isBusy, isFalse);
      expect(service.acquireSession(peer), isTrue);
    });

    test('a status-only channel closing keeps the live session busy', () async {
      final service = serviceWithEngine(FakeSttEngine());
      final owner = FakeDictationChannel();
      unawaited(service.handleChannel(owner));
      owner.sendCommand(DictationCommand.start);
      await until(() => service.isBusy, reason: 'owner lease');

      final statusOnly = FakeDictationChannel();
      final statusRun = service.handleChannel(statusOnly);
      await statusOnly.awaitEvent('stt_status');
      expect(statusOnly.eventsOf('stt_status').last['busy'], isTrue);

      await statusOnly.close();
      await statusRun;

      expect(
        service.isBusy,
        isTrue,
        reason: 'a status/refused connection must never release another lease',
      );

      final third = FakeDictationChannel();
      unawaited(service.handleChannel(third));
      third.sendCommand(DictationCommand.start);
      final refusal = await third.awaitEvent('dictation_error');
      expect(refusal['code'], 'dictation_busy');

      await third.close();
      await owner.close();
      await until(() => !service.isBusy, reason: 'owner teardown');
    });

    test('closing during the model load frees the engine and the lease', () async {
      final engine = FakeSttEngine();
      final gate = Completer<void>();
      engine.startGate = gate;
      final service = serviceWithEngine(engine);
      final channel = FakeDictationChannel();
      final run = service.handleChannel(channel);

      channel.sendCommand(DictationCommand.start);
      await until(() => engine.started, reason: 'load started');
      expect(service.isBusy, isTrue);

      // The peer leaves while the recognizer is still loading.
      await channel.close();
      expect(engine.disposed, isFalse, reason: 'load still in flight');

      gate.complete();
      await run;
      await until(() => engine.disposed, reason: 'abandoned engine freed');
      expect(
        service.isBusy,
        isFalse,
        reason: 'the lease is released only after the engine is gone',
      );
      expect(
        channel.eventsOf('dictation_ready'),
        isEmpty,
        reason: 'a closed channel never receives a ready session',
      );
    });

    test('cancel during the model load publishes no session', () async {
      final engine = FakeSttEngine();
      final gate = Completer<void>();
      engine.startGate = gate;
      final service = serviceWithEngine(engine);
      final channel = FakeDictationChannel();
      final run = service.handleChannel(channel);

      channel.sendCommand(DictationCommand.start);
      await until(() => engine.started, reason: 'load started');

      channel.sendCommand(DictationCommand.cancel);
      gate.complete();
      await until(() => !service.isBusy, reason: 'abandoned start released');
      expect(engine.disposed, isTrue);
      expect(
        channel.eventsOf('dictation_ready'),
        isEmpty,
        reason: 'a cancelled load must not announce a ready session',
      );
      expect(engine.audioLengths, isEmpty);

      await channel.close();
      await run;
    });

    test('a failed engine load is a typed status, never a dead daemon', () async {
      // v1.0.22 shipped a Linux runtime whose ggml siblings did not resolve, and
      // the resulting `SttException` escaped the connection: the daemon exited
      // 255, every client socket died, and the clip that started the session got
      // no `dictation_ready` and no `dictation_error`. An engine that cannot be
      // loaded is a typed answer, exactly like a missing runtime.
      final engine = FakeSttEngine(
        startFailure: const SttException(
          'engine_load_failed',
          'Failed to load dynamic library: libggml.so.0',
        ),
      );
      final service = serviceWithEngine(engine);
      final channel = FakeDictationChannel();
      final run = service.handleChannel(channel);

      channel.sendCommand(DictationCommand.start);
      final error = await channel.awaitEvent('dictation_error');
      expect(error['code'], 'engine_load_failed');
      expect(error['reason'], 'engine_load_failed');
      // The wire payload never carries the library path: a dictation_error also
      // travels over the hosted relay.
      expect('${error['message']}', isNot(contains('libggml')));

      await until(
        () => channel.eventsOf('stt_status').last['ready'] == false,
        reason: 'the failed status is published',
      );
      final failedStatus = channel.eventsOf('stt_status').last;
      expect(failedStatus['reason'], 'engine_load_failed');
      expect(
        failedStatus['supported'],
        isTrue,
        reason: 'the device still supports dictation; this load failed',
      );
      expect(
        channel.eventsOf('dictation_ready'),
        isEmpty,
        reason: 'no session may be announced for an engine that never loaded',
      );
      expect(service.isBusy, isFalse, reason: 'the failed load releases the lease');
      expect(engine.disposed, isTrue);

      // The connection is still serving: a status request is answered instead of
      // the process being gone.
      final before = channel.eventsOf('stt_status').length;
      channel.sendCommand(DictationCommand.status);
      await until(
        () => channel.eventsOf('stt_status').length > before,
        reason: 'status answered after the failure',
      );

      await channel.close();
      await run;
    });

    test('a later connection acquires the lease again', () async {
      final service = serviceWithEngine(FakeSttEngine());

      final first = FakeDictationChannel();
      unawaited(service.handleChannel(first));
      first.sendCommand(DictationCommand.start);
      await until(() => service.isBusy, reason: 'first lease');
      first.sendCommand(DictationCommand.stop);
      await until(() => !service.isBusy, reason: 'first release');
      await first.close();
      await until(() => first.closed, reason: 'first channel closed');

      final second = FakeDictationChannel();
      unawaited(service.handleChannel(second));
      second.sendCommand(DictationCommand.start);
      await until(() => service.isBusy, reason: 'second lease');
      expect(
        second.eventsOf('dictation_error'),
        isEmpty,
        reason: 'no busy refusal for a clean handoff',
      );
      await second.close();
      await until(() => !service.isBusy, reason: 'second release');
    });

    test('the drain finishes before the lease is released', () async {
      final engine = FakeSttEngine();
      final finish = Completer<void>();
      engine.finishGate = finish;
      final service = serviceWithEngine(engine);
      final channel = FakeDictationChannel();
      unawaited(service.handleChannel(channel));
      channel.sendCommand(DictationCommand.start);
      await until(() => service.isBusy, reason: 'lease');

      channel.sendCommand(DictationCommand.stop);
      await until(() => engine.finishCalled, reason: 'drain started');
      expect(
        service.isBusy,
        isTrue,
        reason: 'the lease covers the engine while it drains',
      );

      finish.complete();
      await until(() => !service.isBusy, reason: 'release after drain');
      expect(engine.disposed, isTrue);
      await channel.close();
    });

    test('a session never receives pre-session audio before it is ready', () async {
      final engine = FakeSttEngine();
      final service = serviceWithEngine(engine);
      final channel = FakeDictationChannel();
      unawaited(service.handleChannel(channel));

      // Audio that arrives before `start` is buffered, not dropped.
      channel.addAudio(const [1, 2, 3, 4]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.audioLengths, isEmpty);

      channel.sendCommand(DictationCommand.start);
      await until(() => service.isBusy, reason: 'lease');
      await until(
        () => engine.audioLengths.isNotEmpty,
        reason: 'pre-session audio flushed',
      );
      expect(engine.audioLengths.single, 4);
      await channel.close();
      await until(() => !service.isBusy, reason: 'teardown');
    });
  });
}
