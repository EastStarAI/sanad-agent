import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Windows shell wrapper used by the Direct execution backend.
///
/// `cmd.exe` decodes the bytes of a batch file with the active console code
/// page. A UTF-8 command that carries non-ASCII arguments therefore reaches a
/// child program as mojibake: under code page 437 an Arabic argument is handed
/// over as `╪╡└ê…`. Moving `chcp 65001` into the command text does not repair
/// it, because the line that carries the arguments is already decoded before
/// `chcp` runs.
///
/// The wrapper separates the two concerns:
///
/// 1. a pure-ASCII wrapper switches `cmd.exe` to code page 65001 as its first
///    executed line (via `%SystemRoot%\System32\chcp.com`), and its own ASCII
///    text is decoded identically by every code page;
/// 2. the model command lives only in a UTF-8 payload file that the wrapper
///    `call`s, so the payload is opened and decoded after the switch instead
///    of arriving in a buffer cmd already decoded under the old code page.
///
/// The payload is UTF-8 without a BOM: a BOM would become part of the first
/// command line. The wrapper keeps the ownership start gate, so no
/// model-requested command runs before the daemon attached its process tree.
/// Internal helpers invoke `%SystemRoot%\System32\` executables directly so
/// they do not depend on child `PATH`, and `%errorlevel%` is reset via `(call )`
/// right before delegating to the payload so wrapper mechanics never leak
/// into command results.
class WindowsShellWrapper {
  const WindowsShellWrapper._();

  /// Code page the wrapper switches to before any command text is read.
  static const int codePage = 65001;

  /// Wrapper that owns the code-page switch and the ownership start gate.
  static const String wrapperFileName = 'command.cmd';

  /// UTF-8 file that holds the model command verbatim.
  static const String payloadFileName = 'payload.cmd';

  /// Marker the daemon writes once it owns the started process tree.
  static const String startGateFileName = 'owned.ready';

  static String _joinPath(String directoryPath, String fileName) {
    if (Platform.isWindows ||
        directoryPath.startsWith(RegExp(r'^[A-Za-z]:[\\/]'))) {
      return p.windows.normalize(p.windows.join(directoryPath, fileName));
    }
    return p.join(directoryPath, fileName);
  }

  static String wrapperPath(String directoryPath) =>
      _joinPath(directoryPath, wrapperFileName);

  static String payloadPath(String directoryPath) =>
      _joinPath(directoryPath, payloadFileName);

  static String startGatePath(String directoryPath) =>
      _joinPath(directoryPath, startGateFileName);

  /// The wrapper text for one command directory.
  ///
  /// Must stay pure ASCII: every line that runs before the payload is decoded
  /// with whatever code page `cmd.exe` starts in. Uses `%~dp0` to reference
  /// sibling files in the same directory so the wrapper script contains no
  /// path characters that could depend on code page or username encoding.
  ///
  /// Invokes `chcp.com` and `ping.exe` from `%SystemRoot%\System32\` directly so
  /// the wrapper does not depend on the child process's resolved `PATH`.
  /// Resets `%errorlevel%` to 0 via `(call )` right before calling the payload
  /// so wrapper operations never leak into the reported command status.
  static String renderWrapper([String? directoryPath]) =>
      '@%SystemRoot%\\System32\\chcp.com $codePage>nul 2>&1\r\n'
      '@echo off\r\n'
      ':wait_for_owner\r\n'
      'if not exist "%~dp0$startGateFileName" (\r\n'
      '  >nul 2>&1 %SystemRoot%\\System32\\ping.exe -n 2 127.0.0.1\r\n'
      '  goto wait_for_owner\r\n'
      ')\r\n'
      '(call )\r\n'
      'call "%~dp0$payloadFileName"\r\n'
      'exit /b %errorlevel%\r\n';

  /// The payload text: the model command verbatim plus a terminating CRLF, so
  /// the last line always runs even when it is a bare `echo`. Normalizes line
  /// breaks to CRLF so `cmd.exe` parses multiline commands reliably.
  static String renderPayload(String command) {
    final normalized = command
        .replaceAll('\r\n', '\n')
        .replaceAll('\n', '\r\n');
    return normalized.endsWith('\r\n') ? normalized : '$normalized\r\n';
  }

  /// Bytes written for [renderWrapper] and [renderPayload].
  ///
  /// UTF-8 without a BOM is the encoding `cmd.exe` honours once its code page
  /// is 65001.
  static List<int> encode(String script) => utf8.encode(script);

  /// True when [script] can be decoded identically under any code page.
  static bool isAsciiOnly(String script) =>
      script.codeUnits.every((unit) => unit < 0x80);
}

/// The wrapper files one Windows command needs.
typedef WindowsShellFiles = ({File wrapper, File payload, File startGate});

/// Creates the wrapper and payload files inside [directoryPath].
Future<WindowsShellFiles> writeWindowsShellFiles({
  required String directoryPath,
  required String command,
}) async {
  final wrapper = File(WindowsShellWrapper.wrapperPath(directoryPath));
  final payload = File(WindowsShellWrapper.payloadPath(directoryPath));
  final startGate = File(WindowsShellWrapper.startGatePath(directoryPath));
  await wrapper.writeAsBytes(
    WindowsShellWrapper.encode(WindowsShellWrapper.renderWrapper(directoryPath)),
    flush: true,
  );
  await payload.writeAsBytes(
    WindowsShellWrapper.encode(WindowsShellWrapper.renderPayload(command)),
    flush: true,
  );
  return (wrapper: wrapper, payload: payload, startGate: startGate);
}
