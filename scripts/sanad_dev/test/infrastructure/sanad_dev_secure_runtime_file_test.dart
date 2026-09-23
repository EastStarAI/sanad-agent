import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/secure_runtime_file.dart';
import 'package:sanad_dev/src/infrastructure/windows_secure_runtime_backend.dart';

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
    final stragglers = await home
        .list()
        .where((entry) => entry.path.contains('.tmp.'))
        .toList();
    expect(stragglers, isEmpty);
  });

  test(
    'Windows replacement failure is typed and removes its temporary file',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-secure-runtime-locked-',
      );
      addTearDown(() => home.delete(recursive: true));
      final destination = '${home.path}${Platform.pathSeparator}runtime.json';
      await secureRuntimeAtomicWrite(home.path, destination, 'old');
      final holder = await Process.start(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', _holdFileExclusiveScript],
        environment: {'SANAD_LOCKED_FILE': destination},
      );
      try {
        final ready = await holder.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10));
        expect(ready, 'READY');
        await expectLater(
          secureRuntimeAtomicWrite(home.path, destination, 'new'),
          throwsA(
            isA<SecureRuntimeFileException>().having(
              (error) => error.code,
              'code',
              'atomic_replace_failed',
            ),
          ),
        );
      } finally {
        holder.kill();
        await holder.exitCode.timeout(const Duration(seconds: 10));
      }

      expect(await File(destination).readAsString(), 'old');
      final stragglers = await home
          .list()
          .where((entry) => entry.path.contains('.tmp.'))
          .toList();
      expect(stragglers, isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test('publication rejects a path that escapes the runtime root', () async {
    final root = await Directory.systemTemp.createTemp(
      'sanad-secure-runtime-escape-',
    );
    addTearDown(() => root.delete(recursive: true));
    final home = Directory('${root.path}${Platform.pathSeparator}home');
    await home.create();
    final escapedPath =
        '${home.path}${Platform.pathSeparator}..${Platform.pathSeparator}'
        'outside.json';

    await expectLater(
      secureRuntimeAtomicWrite(home.path, escapedPath, 'unsafe'),
      throwsA(
        isA<SecureRuntimeFileException>().having(
          (error) => error.code,
          'code',
          'outside_home',
        ),
      ),
    );
    expect(
      await File('${root.path}${Platform.pathSeparator}outside.json').exists(),
      isFalse,
    );
  });

  test('publication rejects a linked or reparse-point path segment', () async {
    final root = await Directory.systemTemp.createTemp(
      'sanad-secure-runtime-link-',
    );
    addTearDown(() => root.delete(recursive: true));
    final home = Directory('${root.path}${Platform.pathSeparator}home');
    final target = Directory('${root.path}${Platform.pathSeparator}target');
    await home.create();
    await target.create();
    final linkedPath = '${home.path}${Platform.pathSeparator}runtime';
    if (Platform.isWindows) {
      final result = await Process.run('cmd.exe', [
        '/c',
        'mklink',
        '/J',
        linkedPath,
        target.path,
      ]);
      if (result.exitCode != 0) {
        markTestSkipped('Windows junction creation is unavailable');
        return;
      }
    } else {
      await Link(linkedPath).create(target.path);
    }

    await expectLater(
      secureRuntimeAtomicWrite(
        home.path,
        '$linkedPath${Platform.pathSeparator}runtime.json',
        'unsafe',
      ),
      throwsA(
        isA<SecureRuntimeFileException>().having(
          (error) => error.code,
          'code',
          'unsafe_directory',
        ),
      ),
    );
    expect(
      await File(
        '${target.path}${Platform.pathSeparator}runtime.json',
      ).exists(),
      isFalse,
    );
  });

  test(
    'Windows publication replaces foreign ACLs with protected owner-only ACLs',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sanad-secure-runtime-acl-',
      );
      addTearDown(() => root.delete(recursive: true));
      final home = Directory('${root.path}${Platform.pathSeparator}home');
      await home.create();
      final nested = Directory(
        '${home.path}${Platform.pathSeparator}runtime'
        '${Platform.pathSeparator}nested',
      );
      final path = '${nested.path}${Platform.pathSeparator}runtime.json';

      final seedResult = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', _seedForeignAclScript],
        environment: {'SANAD_ACL_PATH': home.path},
      );
      expect(seedResult.exitCode, 0, reason: seedResult.stderr.toString());

      await secureRuntimeAtomicWrite(home.path, path, 'secure');

      final inspectResult = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', _inspectAclScript],
        environment: {
          'SANAD_ACL_HOME': home.path,
          'SANAD_ACL_NESTED': nested.path,
          'SANAD_ACL_FILE': path,
        },
      );
      expect(
        inspectResult.exitCode,
        0,
        reason: inspectResult.stderr.toString(),
      );
      final lines = inspectResult.stdout.toString().trim().split(
        RegExp(r'\r?\n'),
      );
      expect(lines, hasLength(4));
      final sid = RegExp.escape(lines.first);
      expect(lines[1], matches(RegExp('^D:P(?:AI)?\\(A;OICI;FA;;;$sid\\)\$')));
      expect(lines[2], matches(RegExp('^D:P(?:AI)?\\(A;OICI;FA;;;$sid\\)\$')));
      expect(lines[3], matches(RegExp('^D:P(?:AI)?\\(A;;FA;;;$sid\\)\$')));
    },
    skip: !Platform.isWindows,
  );

  test('atomic publication tolerates an immediate consumer delete', () async {
    final home = await Directory.systemTemp.createTemp(
      'sanad-secure-runtime-write-',
    );
    addTearDown(() => home.delete(recursive: true));
    final path = '${home.path}${Platform.pathSeparator}request.json';

    for (var iteration = 0; iteration < 10; iteration++) {
      final write = secureRuntimeAtomicWrite(home.path, path, '{}\n');
      final file = File(path);
      await (() async {
        while (!await file.exists()) {
          await Future<void>.delayed(Duration.zero);
        }
      })().timeout(const Duration(seconds: 5));
      await file.delete();
      await write.timeout(const Duration(seconds: 5));
    }
  });

  test(
    'concurrent readers and writers do not observe partial content or leave stragglers',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-secure-runtime-concurrent-rw-',
      );
      addTearDown(() => home.delete(recursive: true));
      final path = '${home.path}${Platform.pathSeparator}data.json';
      await secureRuntimeAtomicWrite(home.path, path, '{"version": 0}');

      var writing = true;
      final expectedPayloads = <String>{'{"version": 0}'};
      for (var i = 1; i <= 15; i++) {
        expectedPayloads.add('{"version": $i, "padding": "${"x" * 200}"}');
      }

      final writeFuture = () async {
        for (var i = 1; i <= 15; i++) {
          final payload = '{"version": $i, "padding": "${"x" * 200}"}';
          await secureRuntimeAtomicWrite(home.path, path, payload);
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        writing = false;
      }();

      final readerErrors = <Object>[];
      final readFutures = List.generate(4, (readerIndex) async {
        while (writing) {
          try {
            final content = await secureRuntimeReadText(home.path, path);
            if (!expectedPayloads.contains(content)) {
              readerErrors.add(
                'Reader $readerIndex observed invalid content: $content',
              );
            }
          } catch (e) {
            readerErrors.add('Reader $readerIndex encountered error: $e');
          }
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      });

      await Future.wait([writeFuture, ...readFutures]);
      expect(readerErrors, isEmpty);

      final finalContent = await File(path).readAsString();
      expect(finalContent, '{"version": 15, "padding": "${"x" * 200}"}');

      final stragglers = await home
          .list()
          .where((entry) => entry.path.contains('.tmp.'))
          .toList();
      expect(stragglers, isEmpty);
    },
  );

  test(
    'concurrent atomic writers to the same destination succeed without stragglers',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-secure-runtime-concurrent-w-',
      );
      addTearDown(() => home.delete(recursive: true));
      final path = '${home.path}${Platform.pathSeparator}concurrent.json';

      final writes = List.generate(8, (i) {
        return secureRuntimeAtomicWrite(
          home.path,
          path,
          '{"writer": $i, "payload": "${"y" * 150}"}',
        );
      });

      await Future.wait(writes);

      final content = await File(path).readAsString();
      final validPayloads = List.generate(
        8,
        (i) => '{"writer": $i, "payload": "${"y" * 150}"}',
      );
      expect(validPayloads, contains(content));

      final stragglers = await home
          .list()
          .where((entry) => entry.path.contains('.tmp.'))
          .toList();
      expect(stragglers, isEmpty);
    },
  );

  test(
    'secureRuntimeAppendFile enforces containment and creates file exclusively',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-secure-runtime-append-',
      );
      addTearDown(() => home.delete(recursive: true));
      final path = '${home.path}${Platform.pathSeparator}append.log';

      final file = await secureRuntimeAppendFile(home.path, path);
      expect(await file.exists(), isTrue);

      final handle = await file.open(mode: FileMode.append);
      await handle.writeString('line 1\n');
      await handle.close();

      final existingFile = await secureRuntimeAppendFile(home.path, path);
      expect(existingFile.path, file.path);
      expect(await File(path).readAsString(), 'line 1\n');

      final escapedPath =
          '${home.path}${Platform.pathSeparator}..${Platform.pathSeparator}outside.log';
      await expectLater(
        secureRuntimeAppendFile(home.path, escapedPath),
        throwsA(
          isA<SecureRuntimeFileException>().having(
            (e) => e.code,
            'code',
            'outside_home',
          ),
        ),
      );
    },
  );

  test(
    'secureRuntimeReadText enforces containment and fails closed on missing files',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-secure-runtime-read-',
      );
      addTearDown(() => home.delete(recursive: true));
      final path = '${home.path}${Platform.pathSeparator}readable.json';

      await expectLater(
        secureRuntimeReadText(home.path, path),
        throwsA(
          isA<SecureRuntimeFileException>().having(
            (e) => e.code,
            'code',
            'unsafe_file',
          ),
        ),
      );

      await secureRuntimeAtomicWrite(home.path, path, '{"read": true}');
      final read = await secureRuntimeReadText(home.path, path);
      expect(read, '{"read": true}');

      final escapedPath =
          '${home.path}${Platform.pathSeparator}..${Platform.pathSeparator}outside.json';
      await expectLater(
        secureRuntimeReadText(home.path, escapedPath),
        throwsA(
          isA<SecureRuntimeFileException>().having(
            (e) => e.code,
            'code',
            'outside_home',
          ),
        ),
      );
    },
  );

  test(
    'Windows native backend throws typed WindowsSecureRuntimeException on native failures',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sanad-secure-runtime-native-failure-',
      );
      addTearDown(() => root.delete(recursive: true));
      final backend = WindowsSecureRuntimeBackend();
      final missingFile =
          '${root.path}${Platform.pathSeparator}missing-file.json';
      final missingSource =
          '${root.path}${Platform.pathSeparator}missing-source.tmp';
      final missingDestination =
          '${root.path}${Platform.pathSeparator}missing-destination.json';

      expect(
        () => backend.restrictPath(missingFile, directory: false),
        throwsA(
          isA<WindowsSecureRuntimeException>().having(
            (e) => e.code,
            'code',
            startsWith('set_dacl_failed:'),
          ),
        ),
      );

      expect(
        () => backend.replaceFile(missingSource, missingDestination),
        throwsA(
          isA<WindowsSecureRuntimeException>().having(
            (e) => e.code,
            'code',
            'move_file_failed',
          ),
        ),
      );
    },
    skip: !Platform.isWindows,
  );
}

const _holdFileExclusiveScript = r'''
$ErrorActionPreference = 'Stop'
$stream = [IO.File]::Open(
  $env:SANAD_LOCKED_FILE,
  [IO.FileMode]::Open,
  [IO.FileAccess]::ReadWrite,
  [IO.FileShare]::None
)
try {
  [Console]::Out.WriteLine('READY')
  [Console]::Out.Flush()
  [Console]::ReadLine() | Out-Null
} finally {
  $stream.Dispose()
}
''';

const _seedForeignAclScript = r'''
$ErrorActionPreference = 'Stop'
$acl = [IO.Directory]::GetAccessControl($env:SANAD_ACL_PATH)
$foreignSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
$rule = [Security.AccessControl.FileSystemAccessRule]::new(
  $foreignSid,
  [Security.AccessControl.FileSystemRights]::ReadAndExecute,
  ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
    [Security.AccessControl.InheritanceFlags]::ObjectInherit),
  [Security.AccessControl.PropagationFlags]::None,
  [Security.AccessControl.AccessControlType]::Allow
)
$acl.AddAccessRule($rule)
[IO.Directory]::SetAccessControl($env:SANAD_ACL_PATH, $acl)
$seeded = [IO.Directory]::GetAccessControl($env:SANAD_ACL_PATH)
$rules = @($seeded.GetAccessRules(
  $true,
  $true,
  [Security.Principal.SecurityIdentifier]
))
if (-not ($rules | Where-Object {
  $_.IdentityReference.Value -eq $foreignSid.Value -and -not $_.IsInherited
})) {
  throw 'Foreign explicit ACE seed failed.'
}
if (-not ($rules | Where-Object { $_.IsInherited })) {
  throw 'Inherited ACE seed failed.'
}
''';

const _inspectAclScript = r'''
$ErrorActionPreference = 'Stop'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Write-Output $sid
$section = [Security.AccessControl.AccessControlSections]::Access
$homeAcl = [IO.Directory]::GetAccessControl($env:SANAD_ACL_HOME)
$nestedAcl = [IO.Directory]::GetAccessControl($env:SANAD_ACL_NESTED)
$fileAcl = [IO.File]::GetAccessControl($env:SANAD_ACL_FILE)
Write-Output $homeAcl.GetSecurityDescriptorSddlForm($section)
Write-Output $nestedAcl.GetSecurityDescriptorSddlForm($section)
Write-Output $fileAcl.GetSecurityDescriptorSddlForm($section)
''';
