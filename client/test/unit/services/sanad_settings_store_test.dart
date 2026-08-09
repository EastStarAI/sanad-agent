import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/infrastructure/local_tools/sanad_settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late Directory fakeHome;
  late SanadSettingsStore store;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'sanad-settings-store-',
    );
    fakeHome = Directory('${tempRoot.path}${Platform.pathSeparator}home')..createSync(recursive: true);
    store = SanadSettingsStore(homeDirectoryPath: fakeHome.path);
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  test('saveAuthDocument writes owner-only auth.json atomically', () async {
    await store.saveAuthDocument({
      'access_token': 'abc',
      'hardware_id': 'dev123',
    });

    final authFile = File(
      '${fakeHome.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}auth.json',
    );
    expect(await authFile.exists(), isTrue);
    final decoded = jsonDecode(await authFile.readAsString());
    expect(decoded['access_token'], 'abc');
    expect(decoded['hardware_id'], 'dev123');
    if (!Platform.isWindows) {
      expect((await authFile.stat()).mode & 0x1ff, 0x180);
    }
    expect(
      authFile.parent.listSync().where((entry) => entry.path.contains('.tmp.')),
      isEmpty,
    );
  });

  test('explicit Sanad Home stores auth directly without nesting', () async {
    final isolatedHome = Directory(
      '${tempRoot.path}${Platform.pathSeparator}isolated-home',
    );
    final isolatedStore = SanadSettingsStore(
      sanadHomePath: isolatedHome.path,
    );

    await isolatedStore.saveAuthDocument({'hardware_id': 'isolated-device'});

    expect(
      File('${isolatedHome.path}${Platform.pathSeparator}auth.json').existsSync(),
      isTrue,
    );
    expect(
      File(
        '${isolatedHome.path}${Platform.pathSeparator}mcp_config.json',
      ).existsSync(),
      isFalse,
    );
  });

  test('runtime SANAD_HOME stores auth directly before home fallback', () async {
    final runtimeHome = Directory(
      '${tempRoot.path}${Platform.pathSeparator}runtime-sanad-home',
    );
    final runtimeStore = SanadSettingsStore(
      environment: {
        'SANAD_HOME': runtimeHome.path,
        'USERPROFILE': fakeHome.path,
      },
    );

    await runtimeStore.saveAuthDocument({'hardware_id': 'runtime-device'});

    expect(
      File('${runtimeHome.path}${Platform.pathSeparator}auth.json').existsSync(),
      isTrue,
    );
    expect(
      File(
        '${fakeHome.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}auth.json',
      ).existsSync(),
      isFalse,
    );
  });

  test('readAuthDocument returns empty map if file is missing', () async {
    expect(await store.readAuthDocument(), isEmpty);
  });

  test('deleteAuthDocument removes the file', () async {
    await store.saveAuthDocument({'test': 'data'});
    await store.deleteAuthDocument();
    final authFile = File(
      '${fakeHome.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}auth.json',
    );
    expect(await authFile.exists(), isFalse);
  });

  test('refuses a symlink target without touching its contents', () async {
    if (Platform.isWindows) return;
    final sanadHome = Directory(
      '${fakeHome.path}${Platform.pathSeparator}.sanad',
    )..createSync(recursive: true);
    final outside = File(
      '${tempRoot.path}${Platform.pathSeparator}outside-auth.json',
    )..writeAsStringSync('{"preserved":true}');
    await Link(
      '${sanadHome.path}${Platform.pathSeparator}auth.json',
    ).create(outside.path);

    await expectLater(
      store.saveAuthDocument({'hardware_id': 'must-not-write'}),
      throwsA(isA<Exception>()),
    );
    expect(await outside.readAsString(), '{"preserved":true}');
  });
}
