import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_agent/core/termination_cleanup.dart';

void main() {
  late StreamController<ProcessSignal> signals;

  setUp(() {
    // Broadcast: the hook watches SIGINT and (off Windows) SIGTERM, and both
    // may be fed from this one stream.
    signals = StreamController<ProcessSignal>.broadcast();
  });

  tearDown(() async {
    await signals.close();
  });

  test('runs the cleanup once and then ends the process', () async {
    var cleanups = 0;
    final exits = <int>[];
    final cleanup = TerminationCleanup(
      cleanup: () async => cleanups++,
      exitProcess: exits.add,
    );
    addTearDown(cleanup.dispose);
    cleanup.install(signals: signals.stream);

    signals.add(ProcessSignal.sigterm);
    await pumpEventQueue();

    expect(cleanups, 1);
    expect(exits, [0]);
    expect(cleanup.isStopping, isTrue);
  });

  test('a repeated signal does not run the cleanup again', () async {
    var cleanups = 0;
    final exits = <int>[];
    final cleanup = TerminationCleanup(
      cleanup: () async => cleanups++,
      exitProcess: exits.add,
    );
    addTearDown(cleanup.dispose);
    cleanup.install(signals: signals.stream);

    signals.add(ProcessSignal.sigterm);
    signals.add(ProcessSignal.sigint);
    await pumpEventQueue();

    expect(cleanups, 1);
    expect(exits, [0]);
  });

  test('the process ends only after the cleanup completes', () async {
    // Ordering is the whole point: removing the endpoint record must finish
    // before the process disappears, and the supervisor allows 500 ms.
    final cleanupDone = Completer<void>();
    final exits = <int>[];
    final cleanup = TerminationCleanup(
      cleanup: () => cleanupDone.future,
      exitProcess: exits.add,
    );
    addTearDown(cleanup.dispose);
    cleanup.install(signals: signals.stream);

    signals.add(ProcessSignal.sigterm);
    await pumpEventQueue();
    expect(exits, isEmpty);

    cleanupDone.complete();
    await pumpEventQueue();
    expect(exits, [0]);
  });

  test('a failed cleanup still ends the process', () async {
    final exits = <int>[];
    final cleanup = TerminationCleanup(
      cleanup: () async => throw StateError('unreadable Home'),
      exitProcess: exits.add,
    );
    addTearDown(cleanup.dispose);
    cleanup.install(signals: signals.stream);

    signals.add(ProcessSignal.sigterm);
    await pumpEventQueue();

    expect(exits, [0]);
  });
}
