import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/infrastructure/local_tools/secure_sanad_home_writer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late Directory fakeHome;
  late SecureSanadHomeWriter writer;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('sanad-secure-writer-');
    fakeHome = Directory(
      '${tempRoot.path}${Platform.pathSeparator}home',
    )..createSync(recursive: true);
    writer = SecureSanadHomeWriter(fakeHome.path);
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test(
    'writeText overwrites existing content and leaves no backup or temp files',
    () async {
      await writer.writeText('settings.json', '{"v":1}');
      await writer.writeText('settings.json', '{"v":2}');

      final file = File(
        '${fakeHome.path}${Platform.pathSeparator}settings.json',
      );
      expect(await file.readAsString(), '{"v":2}');

      final leftovers = fakeHome
          .listSync()
          .where(
            (e) => e.path.endsWith('.bak') || e.path.contains('.tmp.'),
          )
          .toList();
      expect(leftovers, isEmpty);
    },
  );
}
