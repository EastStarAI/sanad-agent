import 'dart:io';
import 'dart:convert';
import 'dart:async';

// Legacy diagnostic only: avoid making the Client package depend on sanad-dev.
// ignore: avoid_relative_lib_imports
import '../../../scripts/sanad_dev/lib/runtime_context.dart';

/// inspect_ui.dart — Agent UI Inspection Tool
///
/// Connects to the running Sanad Flutter client via Dart VM Service and calls
/// the custom `ext.sanad_client.inspect_ui` extension to dump all visible
/// widgets with their keys, text, and hints.
///
/// Prerequisites:
///   - App running with --print-dtd and driver extensions:
///     fvm flutter run -d macos --print-dtd -t lib/driver_main.dart
///
/// Usage:
///   fvm dart test/interactive/inspect_ui.dart
///
/// The script auto-discovers the VM Service URL recorded by `sanad-dev run
/// --driver` for the current Git worktree. To override it, set VM_SERVICE_URL:
///   VM_SERVICE_URL="http://127.0.0.1:PORT/TOKEN/" fvm dart test/interactive/inspect_ui.dart

Future<void> main() async {
  String? serviceUrl = Platform.environment['VM_SERVICE_URL'];

  serviceUrl ??= await _discoverWorktreeVmServiceUrl();

  if (serviceUrl == null) {
    print('Error: VM_SERVICE_URL not set and could not be auto-discovered.');
    print('Please set VM_SERVICE_URL environmental variable. Example:');
    print('  VM_SERVICE_URL="http://127.0.0.1:53105/TOKEN/" fvm dart test/interactive/inspect_ui.dart');
    exit(1);
  }

  // Convert the VM HTTP endpoint to its WebSocket endpoint exactly once.
  var wsBase = serviceUrl.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
  while (wsBase.endsWith('/')) {
    wsBase = wsBase.substring(0, wsBase.length - 1);
  }
  final wsUrl = '$wsBase/ws';
  print('Connecting to Dart VM Service at: $wsUrl');

  final socket = await WebSocket.connect(wsUrl);
  print('Connected to WebSocket!');

  final completer = Completer<String>();
  int requestId = 1;
  String? isolateId;

  socket.listen(
    (message) {
      final response = json.decode(message as String);

      if (response['id'] == 1) {
        final result = response['result'];
        if (result != null && result['isolates'] != null && result['isolates'].isNotEmpty) {
          isolateId = result['isolates'][0]['id'];
          print('Found Isolate ID: $isolateId');

          requestId = 2;
          socket.add(
            json.encode({
              'jsonrpc': '2.0',
              'method': 'ext.sanad_client.inspect_ui',
              'params': {'isolateId': isolateId},
              'id': requestId,
            }),
          );
        } else {
          print('Error: No active isolates found.');
          unawaited(socket.close());
          exit(1);
        }
      } else if (response['id'] == 2) {
        if (response['error'] != null) {
          print('Extension Error: ${response['error']}');
        } else {
          completer.complete(json.encode(response['result']));
        }
        unawaited(socket.close());
      }
    },
    onError: (err) {
      print('WebSocket Error: $err');
      completer.completeError(err);
    },
    onDone: () {
      if (!completer.isCompleted) {
        completer.completeError('Socket closed early');
      }
    },
  );

  // Send getVM to discover isolate
  socket.add(
    json.encode({
      'jsonrpc': '2.0',
      'method': 'getVM',
      'params': {},
      'id': 1,
    }),
  );

  try {
    final resultStr = await completer.future.timeout(const Duration(seconds: 15));
    final resultObj = json.decode(resultStr);
    print('\n--- UI Elements Crawler Output ---');
    final elements = resultObj['elements'] as List?;
    if (elements != null) {
      for (final el in elements) {
        final keyPart = el['key'] != null ? ' (key: ${el['key']})' : '';
        final textPart = el['text'] != null ? ' text: "${el['text']}"' : '';
        final hintPart = el['hint'] != null ? ' hint: "${el['hint']}"' : '';
        print('- ${el['type']}$keyPart$textPart$hintPart');
      }
    } else {
      print(resultStr);
    }
    print('----------------------------------\n');
  } catch (e) {
    print('Error calling service extension: $e');
  }
}

Future<String?> _discoverWorktreeVmServiceUrl() async {
  try {
    final runtime = await discoverSanadDevRuntime(
      callerDirectory: Directory.current.path,
    );
    final record = await readRuntimeRecord(runtime);
    final port = record?.vmServicePort;
    if (port != null && await isProcessRunning(record?.clientPid)) {
      return 'http://127.0.0.1:$port/';
    }
  } catch (_) {}
  return null;
}
