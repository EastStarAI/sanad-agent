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
    expect(exits, [signalExitCode(ProcessSignal.sigterm)]);
    expect(exits, [143]);
    expect(cleanup.isStopping, isTrue);
  });

  test('each signal keeps its own signal status', () async {
    // The process used to exit 0 here, which a supervisor reads as a requested
    // clean stop (`launchd` KeepAlive{SuccessfulExit=false} would never
    // relaunch) and a shell reads as success. A signal death is 128 + number:
    // 143 for SIGTERM, 130 for SIGINT.
    final termExits = <int>[];
    final termCleanup = TerminationCleanup(
      cleanup: () async {},
      exitProcess: termExits.add,
    );
    addTearDown(termCleanup.dispose);
    termCleanup.install(signals: signals.stream);

    signals.add(ProcessSignal.sigterm);
    await pumpEventQueue();
    expect(termExits, [143]);

    final intExits = <int>[];
    final intCleanup = TerminationCleanup(
      cleanup: () async {},
      exitProcess: intExits.add,
    );
    addTearDown(intCleanup.dispose);
    intCleanup.install(signals: signals.stream);

    signals.add(ProcessSignal.sigint);
    await pumpEventQueue();
    expect(intExits, [130]);
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
    expect(exits, [143]);
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
    expect(exits, [143]);
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

    expect(exits, [143]);
  });
}
