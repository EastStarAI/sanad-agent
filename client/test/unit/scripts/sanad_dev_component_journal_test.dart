import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../scripts/sanad_dev/component_journal.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-journal-test-');
  });

  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
  });

  ComponentJournalWriter writer({
    String component = 'agent',
    int? vmServicePort,
    int segmentBytes = componentJournalSegmentBytes,
    int retainedSegments = componentJournalRetainedSegments,
  }) => ComponentJournalWriter(
    sanadHome: home.path,
    agentPort: 58091,
    component: component,
    vmServicePort: vmServicePort,
    launcherId: 'launcher-test',
    runtimeNonce: 'nonce-test',
    maxSegmentBytes: segmentBytes,
    retainedSegments: retainedSegments,
  );

  test('history preserves complete ordered component output', () async {
    final journal = writer(component: 'client', vmServicePort: 51091);
    await journal.open();
    for (final entry in <(ComponentOutputSource, String)>[
      (ComponentOutputSource.stdout, 'Flutter build output\n'),
      (ComponentOutputSource.stdout, 'logger output\n'),
      (ComponentOutputSource.stdout, 'print output\n'),
      (ComponentOutputSource.stderr, 'stderr output\n'),
      (ComponentOutputSource.stderr, 'Uncaught error\n#0 stack frame\n'),
    ]) {
      await journal.add(entry.$1, utf8.encode(entry.$2));
    }
    await journal.close(exitCode: 1);

    final lines = await readComponentJournalTail(
      sanadHome: home.path,
      agentPort: 58091,
      key: componentJournalKey(component: 'client', vmServicePort: 51091),
    );

    expect(
      lines,
      containsAllInOrder([
        'Flutter build output',
        'logger output',
        'print output',
        'stderr output',
        'Uncaught error',
        '#0 stack frame',
      ]),
    );
    expect(lines.last, contains('exited with code 1'));
  });

  test('snapshot plus follow has no gap or duplicate', () async {
    final journal = writer();
    await journal.open();
    await journal.add(ComponentOutputSource.stdout, utf8.encode('history\n'));
    final snapshot = await readComponentJournalSnapshot(
      sanadHome: home.path,
      agentPort: 58091,
      key: 'agent',
    );
    final live = followComponentJournal(
      sanadHome: home.path,
      agentPort: 58091,
      key: 'agent',
      initialOffsets: snapshot.offsets,
      pollInterval: const Duration(milliseconds: 5),
    ).map((bytes) => utf8.decode(bytes)).take(2).toList();

    await journal.add(ComponentOutputSource.stdout, utf8.encode('live-one\n'));
    await journal.add(ComponentOutputSource.stderr, utf8.encode('live-two\n'));

    expect(utf8.decode(snapshot.bytes), contains('history\n'));
    expect(await live.timeout(const Duration(seconds: 2)), [
      'live-one\n',
      'live-two\n',
    ]);
    await journal.close();
  });

  test('rotation is bounded and sensitive values are redacted', () async {
    final journal = writer(segmentBytes: 300, retainedSegments: 2);
    await journal.open();
    for (var index = 0; index < 12; index++) {
      await journal.add(
        ComponentOutputSource.stdout,
        utf8.encode('line-$index api_key=secret-value padding-padding-padding\n'),
      );
    }
    await journal.close();

    final segments = await componentJournalSegments(
      sanadHome: home.path,
      agentPort: 58091,
      key: 'agent',
    );
    expect(segments.length, lessThanOrEqualTo(2));
    final output = utf8.decode(
      await readComponentJournalBytes(
        sanadHome: home.path,
        agentPort: 58091,
        key: 'agent',
      ),
    );
    expect(output, isNot(contains('secret-value')));
    expect(output, contains('[REDACTED]'));
  });

  test('process crash output remains readable after process exit', () async {
    late String executable;
    late List<String> arguments;
    if (Platform.isWindows) {
      final fixture = File('${home.path}${Platform.pathSeparator}fixture.cmd');
      await fixture.writeAsString('''@echo off
echo fixture print
echo fixture stderr 1>&2
echo fixture uncaught 1>&2
echo #0 1>&2
exit /b 7
''');
      executable = 'cmd.exe';
      arguments = ['/d', '/c', fixture.path];
    } else {
      final fixture = File('${home.path}${Platform.pathSeparator}fixture.sh');
      await fixture.writeAsString('''#!/bin/sh
printf 'fixture print\\n'
printf 'fixture stderr\\nfixture uncaught\\n#0\\n' >&2
exit 7
''');
      await Process.run('chmod', ['+x', fixture.path]);
      executable = fixture.path;
      arguments = const [];
    }
    final process = await Process.start(executable, arguments);
    final journal = await ComponentProcessJournal.attach(
      process: process,
      writer: writer(),
    );
    expect(await process.exitCode, isNonZero);
    await journal.cancel();

    final output = utf8.decode(
      await readComponentJournalBytes(
        sanadHome: home.path,
        agentPort: 58091,
        key: 'agent',
      ),
    );
    expect(output, contains('fixture print'));
    expect(output, contains('fixture stderr'));
    expect(output, contains('fixture uncaught'));
    expect(output, contains('#0'));
  });
}
