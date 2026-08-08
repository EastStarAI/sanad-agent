import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/infrastructure/local_tools/secure_sanad_home_writer.dart';

void main() {
  test('secure writer atomically replaces an existing file', () async {
    final home = await Directory.systemTemp.createTemp(
      'sanad-secure-home-writer-',
    );
    addTearDown(() => home.delete(recursive: true));
    final writer = SecureSanadHomeWriter(home.path);

    await writer.writeText('auth.json', 'old');
    await writer.writeText('auth.json', 'new');

    expect(await File('${home.path}${Platform.pathSeparator}auth.json').readAsString(), 'new');
    final stragglers = await home.list().where((entry) => entry.path.contains('.tmp.')).toList();
    expect(stragglers, isEmpty);
  });
}
