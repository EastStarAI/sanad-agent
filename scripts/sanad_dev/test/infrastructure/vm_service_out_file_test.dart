import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/src/infrastructure/vm_service_out_file.dart';
import 'package:test/test.dart';

/// The launcher records the authenticated DDS URI through Flutter's documented
/// `--vmservice-out-file` handoff. Discovery must accept it only for the exact
/// live client, port, Home, and owner-only file, and must never splice an
/// upstream token onto a different DDS bind port.
void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-dev-vm-out-');
  });

  tearDown(() async {
    if (home.existsSync()) await home.delete(recursive: true);
  });

  Future<File> writeRecording(
    String contents, {
    int port = 51021,
    int mode = 0x180,
  }) async {
    final path = vmServiceOutFilePath(sanadHome: home.path, vmServicePort: port);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(contents, flush: true);
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', [mode.toRadixString(8), path]);
      expect(result.exitCode, 0);
    }
    return file;
  }

  List<String> liveArguments(String path) => [
    'flutter',
    'run',
    '-d',
    'chrome',
    '--host-vmservice-port=51021',
    '--vmservice-out-file=$path',
  ];

  test('returns the recorded code for the exact live client and DDS port', () async {
    final file = await writeRecording(
      'ws://127.0.0.1:51021/AbCdEf123456/ws',
    );

    final code = await readVmServiceAuthCodeFromOutFile(
      outFilePath: file.path,
      expectedPort: 51021,
      liveClientArguments: liveArguments(file.path),
    );

    expect(code, 'AbCdEf123456');
  });

  test('rejects a URI recorded on the upstream port, not the DDS port', () async {
    // The exact failing shape today: the process carries a 12-char upstream
    // token for :44456 while the DDS endpoint is :51021.
    final file = await writeRecording(
      'ws://127.0.0.1:44456/AbCdEf123456/ws',
    );

    final code = await readVmServiceAuthCodeFromOutFile(
      outFilePath: file.path,
      expectedPort: 51021,
      liveClientArguments: liveArguments(file.path),
    );

    expect(code, isNull);
  });

  test('rejects a missing recording', () async {
    final path = vmServiceOutFilePath(
      sanadHome: home.path,
      vmServicePort: 51021,
    );

    final code = await readVmServiceAuthCodeFromOutFile(
      outFilePath: path,
      expectedPort: 51021,
      liveClientArguments: liveArguments(path),
    );

    expect(code, isNull);
  });

  test('rejects invalid content and non-loopback hosts', () async {
    final invalid = await writeRecording('not a uri');
    final remote = await writeRecording('ws://10.1.2.3:51021/AbCdEf123456/ws');

    for (final file in [invalid, remote]) {
      final code = await readVmServiceAuthCodeFromOutFile(
        outFilePath: file.path,
        expectedPort: 51021,
        liveClientArguments: liveArguments(file.path),
      );
      expect(code, isNull, reason: file.path);
    }
  });

  test('rejects a stale recording beyond the freshness bound', () async {
    final file = await writeRecording(
      'ws://127.0.0.1:51021/AbCdEf123456/ws',
    );

    final code = await readVmServiceAuthCodeFromOutFile(
      outFilePath: file.path,
      expectedPort: 51021,
      liveClientArguments: liveArguments(file.path),
      now: () => DateTime.now().add(vmServiceOutFileMaxAge * 2),
    );

    expect(code, isNull);
  });

  test('rejects a recording the live client did not name', () async {
    final file = await writeRecording(
      'ws://127.0.0.1:51021/AbCdEf123456/ws',
    );

    final code = await readVmServiceAuthCodeFromOutFile(
      outFilePath: file.path,
      expectedPort: 51021,
      liveClientArguments: const ['flutter', 'run', '-d', 'chrome'],
    );

    expect(code, isNull);
  });

  test('rejects group- or world-readable recordings', () async {
    if (Platform.isWindows) return;
    final file = await writeRecording(
      'ws://127.0.0.1:51021/AbCdEf123456/ws',
      mode: 0x1A4, // 0644
    );

    final code = await readVmServiceAuthCodeFromOutFile(
      outFilePath: file.path,
      expectedPort: 51021,
      liveClientArguments: liveArguments(file.path),
    );

    expect(code, isNull);
  });

  test('rejects a symlinked recording', () async {
    if (Platform.isWindows) return;
    final path = vmServiceOutFilePath(
      sanadHome: home.path,
      vmServicePort: 51021,
    );
    await Directory(p.dirname(path)).create(recursive: true);
    final target = File(p.join(home.path, 'elsewhere.uri'));
    await target.writeAsString('ws://127.0.0.1:51021/AbCdEf123456/ws');
    await Link(path).create(target.path);

    final code = await readVmServiceAuthCodeFromOutFile(
      outFilePath: path,
      expectedPort: 51021,
      liveClientArguments: liveArguments(path),
    );

    expect(code, isNull);
  });

  test('prepare replaces a previous recording with an owner-only file', () async {
    final old = await writeRecording('ws://127.0.0.1:51021/stale0000/ws');

    final prepared = await prepareVmServiceOutFile(
      sanadHome: home.path,
      vmServicePort: 51021,
    );

    expect(prepared, old.path);
    expect(await File(prepared!).readAsString(), isEmpty);
    if (!Platform.isWindows) {
      final stat = await File(prepared).stat();
      expect(stat.mode & 0x1FF, 0x180);
    }
  });

  test('remove deletes only the named client recording', () async {
    final file = await writeRecording('ws://127.0.0.1:51021/AbCdEf123456/ws');

    await removeVmServiceOutFile(sanadHome: home.path, vmServicePort: 51021);

    expect(await file.exists(), isFalse);
  });
}
