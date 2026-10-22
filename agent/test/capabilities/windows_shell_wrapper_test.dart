import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/execution/windows_shell_wrapper.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsShellWrapper', () {
    test('constants match the Windows UTF-8 execution contract', () {
      expect(WindowsShellWrapper.codePage, 65001);
      expect(WindowsShellWrapper.wrapperFileName, 'command.cmd');
      expect(WindowsShellWrapper.payloadFileName, 'payload.cmd');
      expect(WindowsShellWrapper.startGateFileName, 'owned.ready');
    });

    test('path helpers construct normalized Windows paths', () {
      const dirWithoutSlash = r'C:\Users\tester\AppData\Local\Temp\sanad-shell-1';
      const dirWithSlash = r'C:\Users\tester\AppData\Local\Temp\sanad-shell-1\';

      expect(
        WindowsShellWrapper.wrapperPath(dirWithoutSlash),
        r'C:\Users\tester\AppData\Local\Temp\sanad-shell-1\command.cmd',
      );
      expect(
        WindowsShellWrapper.wrapperPath(dirWithSlash),
        r'C:\Users\tester\AppData\Local\Temp\sanad-shell-1\command.cmd',
      );

      expect(
        WindowsShellWrapper.payloadPath(dirWithoutSlash),
        r'C:\Users\tester\AppData\Local\Temp\sanad-shell-1\payload.cmd',
      );
      expect(
        WindowsShellWrapper.payloadPath(dirWithSlash),
        r'C:\Users\tester\AppData\Local\Temp\sanad-shell-1\payload.cmd',
      );

      expect(
        WindowsShellWrapper.startGatePath(dirWithoutSlash),
        r'C:\Users\tester\AppData\Local\Temp\sanad-shell-1\owned.ready',
      );
      expect(
        WindowsShellWrapper.startGatePath(dirWithSlash),
        r'C:\Users\tester\AppData\Local\Temp\sanad-shell-1\owned.ready',
      );
    });

    test('renderWrapper generates pure ASCII start gate and payload call', () {
      final wrapper = WindowsShellWrapper.renderWrapper();

      expect(
        wrapper.startsWith(
          r'@%SystemRoot%\System32\chcp.com 65001>nul 2>&1' '\r\n',
        ),
        isTrue,
      );
      expect(wrapper, contains(r'@%SystemRoot%\System32\chcp.com'));
      expect(wrapper, contains('@echo off\r\n'));
      expect(wrapper, contains(':wait_for_owner\r\n'));
      expect(wrapper, contains('if not exist "%~dp0owned.ready" (\r\n'));
      expect(wrapper, contains(r'%SystemRoot%\System32\ping.exe'));
      expect(
        wrapper,
        contains(
          r'>nul 2>&1 %SystemRoot%\System32\ping.exe -n 2 127.0.0.1' '\r\n',
        ),
      );
      expect(wrapper, contains('goto wait_for_owner\r\n'));
      expect(wrapper, contains('(call )\r\ncall "%~dp0payload.cmd"\r\n'));
      expect(wrapper.endsWith('exit /b %errorlevel%\r\n'), isTrue);

      final resetIndex = wrapper.indexOf('(call )\r\n');
      final callIndex = wrapper.indexOf('call "%~dp0payload.cmd"\r\n');
      expect(resetIndex, isNonNegative);
      expect(callIndex, isNonNegative);
      expect(resetIndex + '(call )\r\n'.length, equals(callIndex));

      expect(WindowsShellWrapper.isAsciiOnly(wrapper), isTrue);
    });

    test('renderWrapper remains pure ASCII even if directory path has Arabic characters', () {
      const arabicPath = r'C:\Users\أحمد\AppData\Local\Temp\sanad-shell-1';
      final wrapper = WindowsShellWrapper.renderWrapper(arabicPath);

      expect(WindowsShellWrapper.isAsciiOnly(wrapper), isTrue);
      expect(wrapper, contains('%~dp0owned.ready'));
      expect(wrapper, contains('%~dp0payload.cmd'));
    });

    test('renderPayload normalizes newlines to CRLF and preserves Unicode', () {
      const arabicCommand = 'dart run bin/greet.dart "مرحبا بك يا بطل"';
      final rendered = WindowsShellWrapper.renderPayload(arabicCommand);

      expect(rendered, '$arabicCommand\r\n');

      const multilineLf = 'echo line1\necho line2\necho line3';
      final renderedMulti = WindowsShellWrapper.renderPayload(multilineLf);
      expect(renderedMulti, 'echo line1\r\necho line2\r\necho line3\r\n');

      const multilineCrlf = 'echo a\r\necho b\r\n';
      expect(WindowsShellWrapper.renderPayload(multilineCrlf), 'echo a\r\necho b\r\n');
    });

    test('encode produces UTF-8 without BOM', () {
      const arabicCommand = 'dart run bin/script.dart "مرحبا"';
      final bytes = WindowsShellWrapper.encode(arabicCommand);

      // Verify no UTF-8 Byte Order Mark (EF BB BF)
      expect(
        bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf,
        isFalse,
        reason: 'UTF-8 BOM would break cmd.exe command parsing on first line',
      );

      // Verify roundtrip fidelity
      expect(utf8.decode(bytes), arabicCommand);

      // Verify Arabic characters are UTF-8 multi-byte
      final arabicOnlyBytes = WindowsShellWrapper.encode('مرحبا');
      expect(arabicOnlyBytes.length, greaterThan('مرحبا'.length));
    });

    test('writeWindowsShellFiles writes wrapper and payload files to disk', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanad-test-shell-');
      addTearDown(() async {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      });

      const arabicCommand = 'echo "مرحبا بالعالم"';
      final files = await writeWindowsShellFiles(
        directoryPath: tempDir.path,
        command: arabicCommand,
      );

      expect(await files.wrapper.exists(), isTrue);
      expect(await files.payload.exists(), isTrue);
      expect(await files.startGate.exists(), isFalse); // Created later by daemon

      final wrapperBytes = await files.wrapper.readAsBytes();
      final wrapperText = utf8.decode(wrapperBytes);
      expect(WindowsShellWrapper.isAsciiOnly(wrapperText), isTrue);
      expect(
        wrapperText,
        contains(r'@%SystemRoot%\System32\chcp.com 65001>nul 2>&1'),
      );
      expect(wrapperText, contains(r'%SystemRoot%\System32\ping.exe'));
      expect(wrapperText, contains('(call )\r\ncall "%~dp0payload.cmd"'));

      final payloadBytes = await files.payload.readAsBytes();
      final payloadText = utf8.decode(payloadBytes);
      expect(payloadText, '$arabicCommand\r\n');
      expect(payloadText, contains('مرحبا بالعالم'));

      // Simulate start gate release
      await files.startGate.writeAsString('owned');
      expect(await files.startGate.exists(), isTrue);
    });
  });
}
