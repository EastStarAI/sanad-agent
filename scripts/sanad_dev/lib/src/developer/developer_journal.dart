part of '../../sanad_dev_cli.dart';

const _defaultInteractiveLogTailLines = 50;

Future<bool> _componentJournalAvailable({
  required String sanadHome,
  required int agentPort,
  required String key,
  required bool wait,
}) async {
  final deadline = DateTime.now().add(
    wait ? const Duration(seconds: 100) : Duration.zero,
  );
  do {
    final segments = await componentJournalSegments(
      sanadHome: sanadHome,
      agentPort: agentPort,
      key: key,
    );
    if (segments.isNotEmpty) return true;
    if (!wait) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  } while (DateTime.now().isBefore(deadline));
  return false;
}

Future<void> _handleComponentJournalLogs({
  required String sanadHome,
  required int agentPort,
  required String key,
  required bool follow,
  required int? tailCount,
  required Future<bool> Function() componentIsActive,
  bool allowStartupGrace = false,
  Duration startupGrace = const Duration(seconds: 100),
  String? interactiveHint,
  Set<String> interactiveKeys = const {'r', 'R'},
  Future<void> Function(String key)? onInteractiveKey,
}) async {
  final snapshot = await readComponentJournalSnapshot(
    sanadHome: sanadHome,
    agentPort: agentPort,
    key: key,
  );
  final text = utf8.decode(snapshot.bytes, allowMalformed: true);
  var history = const LineSplitter().convert(text);
  if (tailCount != null && tailCount > 0 && history.length > tailCount) {
    history = history.sublist(history.length - tailCount);
  }
  for (final line in history) {
    print(line);
  }
  if (!follow) return;

  print(
    interactiveHint ??
        '--- Streaming managed process journal (Press Ctrl+C to exit) ---',
  );
  StreamSubscription<List<int>>? stdinSubscription;
  var interactiveActionInProgress = false;
  if (onInteractiveKey != null && stdin.hasTerminal) {
    try {
      stdin.lineMode = false;
      stdin.echoMode = false;
    } on Object {
      // Continue with terminal defaults when raw input is unavailable.
    }
    stdinSubscription = stdin.listen((bytes) {
      for (final byte in bytes) {
        final key = String.fromCharCode(byte);
        if (!interactiveKeys.contains(key) || interactiveActionInProgress) {
          continue;
        }
        interactiveActionInProgress = true;
        unawaited(
          onInteractiveKey(key).whenComplete(() {
            interactiveActionInProgress = false;
          }),
        );
      }
    });
  }

  // Ctrl+C must restore the terminal before exit; on Windows the process is
  // otherwise killed before the finally block below runs.
  final sigintSubscription = ProcessSignal.sigint.watch().listen((_) {
    if (stdin.hasTerminal) {
      try {
        stdin.lineMode = true;
        stdin.echoMode = true;
      } on Object {
        // The host terminal may not expose mutable modes.
      }
    }
    exit(0);
  });

  var seenActive = false;
  final graceDeadline = DateTime.now().add(startupGrace);
  try {
    await for (final bytes in followComponentJournal(
      sanadHome: sanadHome,
      agentPort: agentPort,
      key: key,
      initialOffsets: snapshot.offsets,
      shouldContinue: () async {
        final active = await componentIsActive();
        if (active) seenActive = true;
        return active ||
            (allowStartupGrace &&
                !seenActive &&
                DateTime.now().isBefore(graceDeadline));
      },
    )) {
      stdout.add(bytes);
    }
  } finally {
    await sigintSubscription.cancel();
    await stdinSubscription?.cancel();
    if (stdin.hasTerminal) {
      try {
        stdin.lineMode = true;
        stdin.echoMode = true;
      } on Object {
        // The host terminal may not expose mutable modes.
      }
    }
  }
}

int resolveManagedClientJournalAgentPort({
  required int fallbackAgentPort,
  int? explicitAgentPort,
  ClientInstance? client,
}) =>
    explicitAgentPort ??
    (client == null ? null : clientAgentPort(client)) ??
    fallbackAgentPort;

Future<void> handleClientLogs(
  bool follow,
  int? tailCount,
  int? portOverride, {
  bool waitForJournal = false,
  String? sanadHomePath,
  int? journalAgentPort,
}) async {
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final vmServicePort = portOverride ?? runtime.vmServicePort;
  final matchingClient = (await discoverClientInstances())
      .where((client) => client.port == vmServicePort)
      .firstOrNull;
  final journalHome = sanadHomePath == null
      ? matchingClient?.launchProfile?.define('SANAD_HOME') ?? runtime.sanadHome
      : runtime.sanadHome;
  final agentPort = resolveManagedClientJournalAgentPort(
    fallbackAgentPort: runtime.agentPort,
    explicitAgentPort: journalAgentPort,
    client: matchingClient,
  );
  final key = componentJournalKey(
    component: 'client',
    vmServicePort: vmServicePort,
  );
  if (await _componentJournalAvailable(
    sanadHome: journalHome,
    agentPort: agentPort,
    key: key,
    wait: waitForJournal,
  )) {
    await _handleComponentJournalLogs(
      sanadHome: journalHome,
      agentPort: agentPort,
      key: key,
      follow: follow,
      tailCount: tailCount,
      allowStartupGrace: waitForJournal,
      startupGrace: sanadDevComponentControlTimeout,
      interactiveHint:
          '--- Client logs (r: reload, R: restart, h: help, d: detach, c: clear, q: quit, Ctrl+C: close logs) ---',
      interactiveKeys: const {'r', 'R', 'h', 'd', 'c', 'q'},
      onInteractiveKey: (key) => _sendManagedClientDeveloperKey(
        sanadHome: journalHome,
        agentPort: agentPort,
        vmServicePort: vmServicePort,
        key: key,
      ),
      componentIsActive: () async {
        final record = await _readRuntimeLauncherRecordSafely(
          journalHome,
          agentPort,
        );
        return record != null && record.vmServicePorts.contains(vmServicePort);
      },
    );
    return;
  }

  final instance = await selectClientInstance(portOverride);
  if (instance == null) exit(1);

  stderr.writeln(
    'Managed process journal not found; using the manual-runtime VM logger fallback. '
    'Flutter build/native output and pre-VM process output are unavailable.',
  );
  final wsUrl = instance.token.isEmpty
      ? 'ws://127.0.0.1:${instance.port}/ws'
      : 'ws://127.0.0.1:${instance.port}/${instance.token}/ws';
  WebSocket? socket;
  try {
    socket = await WebSocket.connect(wsUrl);
  } catch (e) {
    print('Error: Could not connect to Dart VM WebSocket at $wsUrl: $e');
    exit(1);
  }

  final completer = Completer<void>();
  String? mainIsolateId;

  socket.listen(
    (message) {
      final response = json.decode(message as String);
      final id = response['id'];

      if (id == 1) {
        final result = response['result'];
        final isolates = result['isolates'] as List;
        if (isolates.isNotEmpty) {
          mainIsolateId = isolates.first['id'] as String;
          // Fetch historical logs
          socket!.add(
            json.encode({
              'jsonrpc': '2.0',
              'method': 'ext.sanad.getLogs',
              'params': {'isolateId': mainIsolateId},
              'id': 2,
            }),
          );
        } else {
          print('No isolates found.');
          completer.complete();
        }
      } else if (id == 2) {
        final result = response['result'];
        if (result != null && result['logs'] != null) {
          var logs = List<String>.from(result['logs']);
          if (tailCount != null && tailCount > 0) {
            if (logs.length > tailCount) {
              logs = logs.sublist(logs.length - tailCount);
            }
          }
          for (final log in logs) {
            print(log);
          }
        } else {
          print('No historical logs returned by the app.');
        }

        if (!follow) {
          completer.complete();
        } else {
          // Subscribe to Stdout and Stderr streams
          socket!.add(
            json.encode({
              'jsonrpc': '2.0',
              'method': 'streamListen',
              'params': {'streamId': 'Stdout'},
              'id': 3,
            }),
          );
          socket.add(
            json.encode({
              'jsonrpc': '2.0',
              'method': 'streamListen',
              'params': {'streamId': 'Stderr'},
              'id': 4,
            }),
          );
          print('--- Streaming live logs (Press Ctrl+C to exit) ---');
        }
      } else {
        final method = response['method'];
        if (method == 'streamNotify') {
          final params = response['params'];
          if (params != null) {
            final event = params['event'];
            if (event != null) {
              final timestamp = event['timestamp'] as int?;
              // Ignore historical stdout events pushed on subscription
              if (timestamp != null && timestamp < startTimestamp) {
                return;
              }
              if (event['bytes'] != null) {
                final base64Bytes = event['bytes'] as String;
                try {
                  final decodedText = utf8.decode(base64.decode(base64Bytes));
                  stdout.write(decodedText);
                } catch (_) {}
              }
            }
          }
        }
      }
    },
    onError: (e) {
      print('WebSocket error: $e');
      completer.complete();
    },
    onDone: () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    },
  );

  // Get Isolates
  socket.add(
    json.encode({'jsonrpc': '2.0', 'method': 'getVM', 'params': {}, 'id': 1}),
  );

  // Handle SIGINT for live stream
  ProcessSignal.sigint.watch().listen((signal) {
    socket?.close();
    exit(0);
  });

  await completer.future;
  await socket.close();
  exit(0);
}

Future<void> handleAgentLogs(
  bool follow,
  int? tailCount,
  int? portOverride, {
  bool waitForInstance = false,
  String? sanadHomePath,
}) async {
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final selectedInstance = sanadHomePath == null
      ? await selectAgentInstance(portOverride)
      : null;
  final activeHome = selectedInstance?.sanadHome ?? runtime.sanadHome;
  final agentPort = portOverride ?? selectedInstance?.port ?? runtime.agentPort;
  const key = 'agent';
  if (await _componentJournalAvailable(
    sanadHome: activeHome,
    agentPort: agentPort,
    key: key,
    wait: waitForInstance,
  )) {
    await _handleComponentJournalLogs(
      sanadHome: activeHome,
      agentPort: agentPort,
      key: key,
      follow: follow,
      tailCount: tailCount,
      allowStartupGrace: waitForInstance,
      startupGrace: sanadDevAgentStartupTimeout,
      interactiveHint:
          '--- Agent logs (r/R: restart, s/q: safe stop, Ctrl+C: close logs) ---',
      interactiveKeys: const {'r', 'R', 's', 'q'},
      onInteractiveKey: (key) => _sendManagedAgentInteractiveKey(
        sanadHome: activeHome,
        agentPort: agentPort,
        key: key,
      ),
      componentIsActive: () async {
        final record = await _readRuntimeLauncherRecordSafely(
          activeHome,
          agentPort,
        );
        return record != null && record.status != 'client-only';
      },
    );
    return;
  }

  AgentInstance? instance = selectedInstance;
  if (waitForInstance && portOverride != null) {
    final workspaceHash = runtime.worktreeId.split('-').last;
    final deadline = DateTime.now().add(const Duration(seconds: 100));
    print('Waiting for Agent logs on port $portOverride...');
    while (DateTime.now().isBefore(deadline)) {
      final agents = await discoverAgentInstances();
      instance = agents
          .where(
            (candidate) =>
                candidate.port == portOverride &&
                candidate.workspaceHash == workspaceHash,
          )
          .firstOrNull;
      if (instance != null) break;
      final record = await readRuntimeLauncherRecord(activeHome, portOverride);
      if (record == null || record.status == 'client-only') break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  } else if (instance == null) {
    instance = await selectAgentInstance(portOverride);
  }
  if (instance == null) {
    stderr.writeln('Agent did not become available for log streaming.');
    exit(1);
  }

  stderr.writeln(
    'Managed process journal not found; using the manual-runtime Agent logger fallback. '
    'print/stderr and pre-health process output may be unavailable.',
  );
  final client = HttpClient();
  List<String> logs = [];
  try {
    final request = await client.getUrl(
      Uri.parse('http://localhost:${instance.port}/logs'),
    );
    await authorizeLocalGatewayRequest(
      request,
      instance.sanadHome ?? runtime.sanadHome,
    );
    final response = await request.close();
    if (response.statusCode == 200) {
      final body = await response.transform(utf8.decoder).join();
      final data = json.decode(body);
      logs = List<String>.from(data['logs'] ?? []);
    } else {
      print('Error fetching logs from agent: HTTP ${response.statusCode}');
      client.close();
      exit(1);
    }
  } catch (e) {
    print(
      'Could not connect to local agent daemon at http://localhost:${instance.port}: $e',
    );
    client.close();
    exit(1);
  }
  client.close();

  if (tailCount != null && tailCount > 0) {
    if (logs.length > tailCount) {
      logs = logs.sublist(logs.length - tailCount);
    }
  }

  for (final log in logs) {
    print(log);
  }

  if (follow) {
    RuntimeLauncherRecord? initialRecord;
    try {
      initialRecord = await readRuntimeLauncherRecord(
        instance.sanadHome ?? activeHome,
        instance.port,
      );
    } on Object {}
    final followsManagedAgent =
        initialRecord != null &&
        initialRecord.launcherId == instance.launcherId &&
        initialRecord.runtimeNonce == instance.runtimeNonce;
    print(
      '--- Streaming live logs (Press Ctrl+C to exit, press R to restart agent) ---',
    );

    StreamSubscription<List<int>>? stdinSub;
    try {
      if (stdin.hasTerminal) {
        try {
          stdin.lineMode = false;
          stdin.echoMode = false;
        } catch (_) {
          // Fall back gracefully if terminal raw mode cannot be set (e.g. on Windows)
        }
        stdinSub = stdin.listen((bytes) {
          final hasR = bytes.any((b) {
            final c = String.fromCharCode(b).toLowerCase();
            return c == 'r';
          });
          if (hasR) {
            print(
              '\n[sanad-dev] Intercepted "r" key. Triggering Agent restart...',
            );
            handleAgentRestart(instance!.port);
          }
        });
      }
    } catch (_) {}

    var shouldExit = false;
    ProcessSignal.sigint.watch().listen((signal) async {
      shouldExit = true;
      await stdinSub?.cancel();
      if (stdin.hasTerminal) {
        try {
          stdin.lineMode = true;
          stdin.echoMode = true;
        } catch (_) {}
      }
      exit(0);
    });

    while (!shouldExit) {
      if (followsManagedAgent) {
        RuntimeLauncherRecord? currentRecord;
        try {
          currentRecord = await readRuntimeLauncherRecord(
            runtime.sanadHome,
            instance.port,
          );
        } on Object {}
        if (currentRecord == null || currentRecord.status == 'client-only') {
          print('\n[sanad-dev] Agent stopped; closing log stream.');
          break;
        }
      }
      WebSocket? ws;
      try {
        ws = await WebSocket.connect(
          'ws://localhost:${instance.port}/ws?type=logs',
          headers: await localGatewayCredentialHeaders(
            instance.sanadHome ?? runtime.sanadHome,
          ),
        ).timeout(const Duration(seconds: 1));
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }

      final completer = Completer<void>();
      ws.listen(
        (message) {
          print(message);
        },
        onError: (e) {
          completer.complete();
        },
        onDone: () {
          completer.complete();
        },
      );

      await completer.future;
      try {
        await ws.close();
      } catch (_) {}

      if (!shouldExit) {
        print('\n[sanad-dev] Connection lost. Reconnecting...');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    await stdinSub?.cancel();
  }
  exit(0);
}
