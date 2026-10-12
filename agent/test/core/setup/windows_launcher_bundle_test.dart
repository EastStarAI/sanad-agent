import 'dart:io';
import 'dart:typed_data';

import 'package:sanad_agent/core/setup/windows_launcher_bundle.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'sanad-windows-launcher-',
    );
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  test('embeds and transactionally extracts the verified launcher', () async {
    final agent = File('${temporaryDirectory.path}/sanad.exe')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    final launcherBytes = _guiExecutableBytes();
    final launcher = File('${temporaryDirectory.path}/launcher.exe')
      ..writeAsBytesSync(launcherBytes);

    await WindowsLauncherBundle.embed(agent: agent, launcher: launcher);
    final installed = await WindowsLauncherBundle.install(
      agentExecutable: agent.path,
      binDirectory: temporaryDirectory.path,
    );

    expect(installed, isNotNull);
    expect(File(installed!).readAsBytesSync(), launcherBytes);
    expect(installed, contains('sanad-launcher-'));
    expect(
      await WindowsLauncherBundle.install(
        agentExecutable: agent.path,
        binDirectory: temporaryDirectory.path,
      ),
      installed,
    );
  });

  test('returns null when an executable has no embedded launcher', () async {
    final agent = File('${temporaryDirectory.path}/sanad.exe')
      ..writeAsBytesSync(List<int>.filled(128, 7));

    expect(
      await WindowsLauncherBundle.install(
        agentExecutable: agent.path,
        binDirectory: temporaryDirectory.path,
      ),
      isNull,
    );
  });

  test('rejects a launcher whose embedded bytes were changed', () async {
    final agent = File('${temporaryDirectory.path}/sanad.exe')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    final launcher = File('${temporaryDirectory.path}/launcher.exe')
      ..writeAsBytesSync(_guiExecutableBytes());
    await WindowsLauncherBundle.embed(agent: agent, launcher: launcher);
    final bytes = agent.readAsBytesSync();
    bytes[4] ^= 0xff;
    agent.writeAsBytesSync(bytes);

    expect(
      () => WindowsLauncherBundle.install(
        agentExecutable: agent.path,
        binDirectory: temporaryDirectory.path,
      ),
      throwsFormatException,
    );
  });
}

List<int> _guiExecutableBytes() {
  final bytes = Uint8List(512);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 0x4d;
  bytes[1] = 0x5a;
  data.setUint32(0x3c, 128, Endian.little);
  bytes[128] = 0x50;
  bytes[129] = 0x45;
  data.setUint16(128 + 24, 0x20b, Endian.little);
  data.setUint16(128 + 24 + 68, 2, Endian.little);
  return bytes;
}
