import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../scripts/sanad_dev/secure_runtime_file.dart';

void main() {
  test('atomic publication replaces an existing runtime file', () async {
    final home = await Directory.systemTemp.createTemp(
      'sanad-secure-runtime-replace-',
    );
    addTearDown(() => home.delete(recursive: true));
    final path = '${home.path}${Platform.pathSeparator}runtime.json';
    await File(path).writeAsString('old');

    await secureRuntimeAtomicWrite(home.path, path, 'new');

    expect(await File(path).readAsString(), 'new');
    final stragglers = await home.list().where((entry) => entry.path.contains('.tmp.')).toList();
    expect(stragglers, isEmpty);
  });

  test(
    'atomic publication tolerates an immediate POSIX consumer delete',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-secure-runtime-write-',
      );
      addTearDown(() => home.delete(recursive: true));
      final path = '${home.path}${Platform.pathSeparator}request.json';

      for (var iteration = 0; iteration < 10; iteration++) {
        final write = secureRuntimeAtomicWrite(home.path, path, '{}\n');
        final file = File(path);
        while (!await file.exists()) {
          await Future<void>.delayed(Duration.zero);
        }
        await file.delete();
        await write;
      }
    },
    skip: Platform.isWindows,
  );
}
