import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/secure_runtime_file.dart';

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
