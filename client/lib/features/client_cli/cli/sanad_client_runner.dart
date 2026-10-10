import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../data/client_cli_discovery.dart';
import '../domain/models/client_cli_exceptions.dart';
import '../domain/models/client_cli_record.dart';

typedef WebSocketConnector = Future<WebSocket> Function(Uri uri, {Map<String, dynamic>? headers});

class SanadClientRunner {
  final ClientCliDiscovery discovery;
  final String version;
  final Uuid uuid;
  final http.Client Function()? httpClientFactory;
  final WebSocketConnector? webSocketConnector;

  const SanadClientRunner({
    this.discovery = const ClientCliDiscovery(),
    this.version = '1.0.15',
    this.uuid = const Uuid(),
    this.httpClientFactory,
    this.webSocketConnector,
  });

  Future<int> run(
    List<String> rawArgs, {
    StringSink? stdoutSink,
    StringSink? stderrSink,
    String? stdinContent,
  }) async {
    final out = stdoutSink ?? stdout;
    final err = stderrSink ?? stderr;

    if (rawArgs.isEmpty || rawArgs.contains('-h') || rawArgs.contains('--help')) {
      _printHelp(out);
      return 0;
    }

    if (rawArgs.contains('-v') || rawArgs.contains('--version')) {
      out.writeln('sanad-client $version');
      return 0;
    }

    // Extract global CLI options
    String? explicitHome;
    String? targetDevice;
    bool jsonOutput = false;
    bool quietOutput = false;
    final remainingArgs = <String>[];

    for (var i = 0; i < rawArgs.length; i++) {
      final arg = rawArgs[i];
      if (arg == '--home' && i + 1 < rawArgs.length) {
        explicitHome = rawArgs[++i];
      } else if (arg.startsWith('--home=')) {
        explicitHome = arg.substring('--home='.length);
      } else if ((arg == '-d' || arg == '--device') && i + 1 < rawArgs.length) {
        targetDevice = rawArgs[++i];
      } else if (arg.startsWith('--device=')) {
        targetDevice = arg.substring('--device='.length);
      } else if (arg == '--json') {
        jsonOutput = true;
        remainingArgs.add(arg);
      } else if (arg == '-q' || arg == '--quiet') {
        quietOutput = true;
        remainingArgs.add(arg);
      } else {
        remainingArgs.add(arg);
      }
    }

    // Subcommand: devices (or device list)
    if (remainingArgs.isNotEmpty &&
        (remainingArgs.first == 'devices' ||
            (remainingArgs.first == 'device' &&
                remainingArgs.length > 1 &&
                remainingArgs[1] == 'list'))) {
      return _listDevices(
        explicitHome: explicitHome,
        jsonOutput: jsonOutput,
        out: out,
        err: err,
      );
    }

    // Forwarded remote command execution
    if (targetDevice == null || targetDevice.trim().isEmpty) {
      err.writeln('Error: Missing target device.');
      err.writeln('Specify a remote device using --device <device_id> or -d <device_id>.');
      err.writeln('Run "sanad-client devices" to discover connected remote devices.');
      return 1;
    }

    if (remainingArgs.isEmpty) {
      err.writeln('Error: No command specified for remote execution.');
      return 1;
    }

    return _executeRemoteCommand(
      explicitHome: explicitHome,
      targetDevice: targetDevice.trim(),
      argv: remainingArgs,
      stdinContent: stdinContent,
      jsonOutput: jsonOutput,
      quietOutput: quietOutput,
      out: out,
      err: err,
    );
  }

  Future<int> _listDevices({
    String? explicitHome,
    required bool jsonOutput,
    required StringSink out,
    required StringSink err,
  }) async {
    final ClientCliRecord record;
    try {
      record = await discovery.discover(
        explicitHome: explicitHome,
        expectedCliVersion: version,
      );
    } on ClientCliException catch (e) {
      err.writeln('Error: ${e.message}');
      return e.exitCode;
    }

    final httpClient = httpClientFactory != null ? httpClientFactory!() : http.Client();
    try {
      final uri = Uri.parse('http://127.0.0.1:${record.port}/devices');
      final response = await httpClient.get(
        uri,
        headers: {
          'x-sanad-client-token': record.token,
          'authorization': 'Bearer ${record.token}',
        },
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        err.writeln('Failed to list devices: HTTP ${response.statusCode} - ${response.body}');
        return 1;
      }

      if (jsonOutput) {
        out.writeln(response.body);
        return 0;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final devices = List<Map<String, dynamic>>.from(data['devices'] as List? ?? []);

      if (devices.isEmpty) {
        out.writeln('No remote devices registered or available in Sanad Client.');
        return 0;
      }

      out.writeln('Available Remote Devices:');
      for (final device in devices) {
        final id = device['id'];
        final name = device['name'];
        final platform = device['platform'];
        final status = device['status'];
        final isCurrent = device['is_current'] == true ? ' (current)' : '';
        out.writeln('  • $id — $name [$platform] ($status)$isCurrent');
      }
      return 0;
    } catch (e) {
      err.writeln('Failed to retrieve devices from Sanad Client: $e');
      return 1;
    } finally {
      httpClient.close();
    }
  }

  Future<int> _executeRemoteCommand({
    String? explicitHome,
    required String targetDevice,
    required List<String> argv,
    String? stdinContent,
    required bool jsonOutput,
    required bool quietOutput,
    required StringSink out,
    required StringSink err,
  }) async {
    final ClientCliRecord record;
    try {
      record = await discovery.discover(
        explicitHome: explicitHome,
        expectedCliVersion: version,
      );
    } on ClientCliException catch (e) {
      err.writeln('Error: ${e.message}');
      return e.exitCode;
    }

    // Materialize local brief file content if passed via --brief-file / -b
    String? briefContent;
    for (var i = 0; i < argv.length; i++) {
      if ((argv[i] == '-b' || argv[i] == '--brief-file') && i + 1 < argv.length) {
        final filePath = argv[i + 1];
        final file = File(filePath);
        if (!await file.exists()) {
          err.writeln('Error: Brief file not found at: $filePath');
          return 2;
        }
        briefContent = await file.readAsString();
        break;
      } else if (argv[i].startsWith('--brief-file=')) {
        final filePath = argv[i].substring('--brief-file='.length);
        final file = File(filePath);
        if (!await file.exists()) {
          err.writeln('Error: Brief file not found at: $filePath');
          return 2;
        }
        briefContent = await file.readAsString();
        break;
      }
    }

    // Read piped stdin if not supplied explicitly
    String? effectiveStdin = stdinContent;
    if (effectiveStdin == null && !stdin.hasTerminal) {
      try {
        effectiveStdin = await stdin.transform(utf8.decoder).join();
      } catch (_) {}
    }

    final requestId = uuid.v4();
    final wsUri = Uri.parse('ws://127.0.0.1:${record.port}/ws?token=${record.token}');

    final completer = Completer<int>();
    WebSocket? webSocket;
    StreamSubscription? signalSub;

    try {
      if (webSocketConnector != null) {
        webSocket = await webSocketConnector!(wsUri);
      } else {
        webSocket = await WebSocket.connect(
          wsUri.toString(),
          headers: {'x-sanad-client-token': record.token},
        );
      }

      // Handle Ctrl+C (SIGINT) by sending cancel request over WebSocket
      int sigintCount = 0;
      if (!Platform.isWindows) {
        signalSub = ProcessSignal.sigint.watch().listen((_) {
          sigintCount++;
          if (sigintCount == 1) {
            webSocket?.add(
              jsonEncode({
                'type': 'cancel',
                'request_id': uuid.v4(),
                'target_request_id': requestId,
              }),
            );
          } else {
            if (!completer.isCompleted) {
              completer.complete(130);
            }
          }
        });
      }

      webSocket.listen(
        (data) {
          try {
            final msg = jsonDecode(data.toString()) as Map<String, dynamic>;
            final type = msg['type']?.toString();

            if (type == 'stdout') {
              out.write(msg['text'] ?? '');
            } else if (type == 'stderr') {
              err.write(msg['text'] ?? '');
            } else if (type == 'event') {
              if (argv.contains('--events')) {
                out.writeln(jsonEncode(msg['event'] ?? msg));
              }
            } else if (type == 'result') {
              final exitCode = msg['exit_code'] as int? ?? 0;
              final error = msg['error']?.toString();
              if (error != null && error.isNotEmpty && exitCode != 0) {
                err.writeln(error);
              }
              if (!completer.isCompleted) {
                completer.complete(exitCode);
              }
            } else if (type == 'error') {
              err.writeln('Error: ${msg['message'] ?? 'Remote execution error'}');
              if (!completer.isCompleted) {
                completer.complete(1);
              }
            }
          } catch (e) {
            err.writeln('Malformed response frame: $e');
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(0);
          }
        },
        onError: (e) {
          err.writeln('Connection error: $e');
          if (!completer.isCompleted) {
            completer.complete(1);
          }
        },
      );

      // Send execution payload
      webSocket.add(
        jsonEncode({
          'type': 'execute',
          'request_id': requestId,
          'device_id': targetDevice,
          'argv': argv,
          'stdin': effectiveStdin,
          'brief_content': briefContent,
          'timeout_seconds': 300,
        }),
      );

      final exitCode = await completer.future;
      return exitCode;
    } catch (e) {
      err.writeln('Failed to execute remote command: $e');
      return 1;
    } finally {
      unawaited(signalSub?.cancel());
      try {
        await webSocket?.close(WebSocketStatus.normalClosure);
      } catch (_) {}
    }
  }

  void _printHelp(StringSink out) {
    out.writeln('''
Sanad Client CLI (sanad-client) — Remote Sanad command relay tool

Usage:
  sanad-client devices [--json]
  sanad-client --device <device_id> <command> [arguments...]

Commands:
  devices                    List registered remote devices

Options:
  -d, --device <id>          Target remote device ID or name (required for commands)
  --home <path>              Custom Sanad Home directory
  --json                     Output structured machine-readable JSON
  -q, --quiet                Suppress non-essential output
  -h, --help                 Show this help documentation
  -v, --version              Show version information

Examples:
  sanad-client devices
  sanad-client -d dev-server-1 ws list --json
  sanad-client -d dev-server-1 run --workspace ws-core --brief-file ./task.md
''');
  }
}
