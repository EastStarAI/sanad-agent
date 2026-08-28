part of '../sanad_dev.dart';

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

Future<void> _sendManagedClientDeveloperKey({
  required String sanadHome,
  required int agentPort,
  required int vmServicePort,
  required String key,
}) async {
  final record = await _readRuntimeLauncherRecordSafely(sanadHome, agentPort);
  if (record == null || !record.vmServicePorts.contains(vmServicePort)) {
    stderr.writeln('Client command refused: managed ownership is unavailable.');
    return;
  }
  final action = runtimeClientActionForInteractiveKey(key);
  if (action == null) return;
  print('\n[sanad-dev] Client ${action.name} requested.');
  final succeeded = await requestManagedComponentAction(
    record,
    action: action,
    target: RuntimeComponentTarget.client,
    vmServicePort: vmServicePort,
    openClientTerminal: false,
    timeout: const Duration(seconds: 10),
  );
  if (!succeeded) exitCode = 1;
}

Future<void> _sendManagedAgentInteractiveKey({
  required String sanadHome,
  required int agentPort,
  required String key,
}) async {
  if (key == 'r' || key == 'R') {
    await handleAgentRestart(agentPort);
    return;
  }
  if (key != 's' && key != 'q') return;

  final record = await _readRuntimeLauncherRecordSafely(sanadHome, agentPort);
  if (record == null) {
    stderr.writeln('Agent stop refused: managed ownership is unavailable.');
    exitCode = 1;
    return;
  }
  print('\n[sanad-dev] Safe Agent stop requested.');
  final succeeded = await requestManagedComponentAction(
    record,
    action: RuntimeComponentAction.stop,
    target: RuntimeComponentTarget.agent,
  );
  if (!succeeded) exitCode = 1;
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
      interactiveHint: '--- Client logs (r: reload, R: restart, h: help, d: detach, c: clear, q: quit, Ctrl+C: close logs) ---',
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

Future<void> handleClientAttachAction(
  String action,
  int? portOverride, {
  String? sanadHomePath,
}) async {
  final instance = await selectClientInstance(
    portOverride,
    sanadHomePath: sanadHomePath,
  );
  if (instance == null) exit(1);

  final vmUrl = instance.token.isEmpty
      ? 'http://127.0.0.1:${instance.port}/'
      : 'http://127.0.0.1:${instance.port}/${instance.token}/';
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final expectedClientDirectory =
      '${runtime.repositoryRoot}${Platform.pathSeparator}client';
  if (!_samePath(instance.path, expectedClientDirectory)) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: the selected '
      'VM service does not belong to ${runtime.worktreeId}.',
    );
    exitCode = 1;
    return;
  }

  final discoveredProfile = instance.launchProfile;
  if (discoveredProfile == null) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: the running '
      'client launch profile could not be discovered.',
    );
    exitCode = 1;
    return;
  }
  final activeAgents = await discoverAgentInstances(
    sanadHomeOverride: sanadHomePath,
  );
  final workspaceHash = runtime.worktreeId.split('-').last;
  final matchingAgents = activeAgents
      .where((agent) => agent.workspaceHash == workspaceHash)
      .toList(growable: false);
  if (matchingAgents.length != 1) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: expected one '
      'running agent for ${runtime.worktreeId}, found ${matchingAgents.length}.',
    );
    exitCode = 1;
    return;
  }
  final primarySanadHome = resolveDefaultUserSanadHome(Platform.environment);
  final profile = withImplicitPrimaryClientDefaults(
    discoveredProfile,
    allowed:
        !runtime.isLinkedWorktree &&
        matchingAgents.single.port == canonicalPrimaryAgentPort &&
        _samePath(runtime.sanadHome, primarySanadHome),
    primarySanadHome: primarySanadHome,
  );
  final profileError = validateClientLaunchProfile(
    profile,
    isLinkedWorktree: runtime.isLinkedWorktree,
    expectedWorktreeName: runtime.worktreeDisplayName,
    expectedBranch: runtime.branch,
    expectedAgentPort: matchingAgents.single.port,
    emptyPreferencesSanadHome: runtime.isLinkedWorktree
        ? resolveDefaultUserSanadHome(Platform.environment)
        : runtime.sanadHome,
    derivePreferencesPrefix: deriveSanadDevPreferencesPrefix,
  );
  if (profileError != null) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: $profileError.',
    );
    exitCode = 1;
    return;
  }
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: selectRuntimeProcessState(
      activeAgents: activeAgents,
      activeClients: await discoverClientInstances(),
      runtime: runtime,
    ),
    sanadHome: profile.define('SANAD_HOME'),
  );
  final selectedClientIsManaged =
      ownership.isManaged &&
      ownership.state.ownedClients.any(
        (client) => client.port == instance.port && client.pid == instance.pid,
      );
  if (!selectedClientIsManaged) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: the selected '
      'client is ${ownership.isManaged ? 'unmanaged' : ownership.classification.name}, not owned by the live '
      'sanad-dev launcher.',
    );
    exitCode = 1;
    return;
  }

  print(
    'Attaching to Flutter app at $vmUrl to perform Hot ${action == 'R' ? 'Restart' : 'Reload'}...',
  );
  final clientDir = instance.path;
  final targetDevice =
      instance.deviceId ?? profile.deviceId ?? _defaultDesktopDevice();
  final attachArguments = buildClientAttachArguments(
    profile: profile,
    vmUrl: vmUrl,
    deviceId: targetDevice,
  );
  const executable = 'fvm';
  final args = ['flutter', ...attachArguments];
  final attachEnvironment = buildUnifiedSanadHomeEnvironment(
    Platform.environment,
    sanadHome: profile.define('SANAD_HOME')!,
  );

  final process = await Process.start(
    executable,
    args,
    workingDirectory: clientDir,
    environment: attachEnvironment,
    runInShell: Platform.isWindows,
  );

  final completer = Completer<void>();
  bool commandSent = false;
  bool actionCompleted = false;

  // Pipe stdout (filtered) and stderr to the console so user can see progress
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) async {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return;

          const ignorePatterns = [
            'Flutter run key commands.',
            'r Hot reload.',
            'R Hot restart.',
            'h List all available interactive',
            'c Clear the screen',
            'q Quit (terminate',
            'A Dart VM Service',
            'Detaching from application...',
            'Application finished.',
            'Waiting for attach to establish connection...',
          ];

          bool ignore = false;
          for (final pattern in ignorePatterns) {
            if (trimmed.startsWith(pattern)) {
              ignore = true;
              break;
            }
          }
          if (!ignore) {
            print(line);
          }

          // Trigger action when the terminal is ready
          if (!commandSent &&
              (trimmed.contains('r Hot reload') ||
                  trimmed.contains('Flutter run key commands'))) {
            commandSent = true;

            final now = DateTime.now();
            final libDir = Directory('$clientDir/lib');
            if (libDir.existsSync()) {
              try {
                final entities = libDir.listSync(recursive: true);
                for (final entity in entities) {
                  if (entity is File && entity.path.endsWith('.dart')) {
                    try {
                      entity.setLastModifiedSync(now);
                    } catch (_) {}
                  }
                }
              } catch (_) {}
            }

            final mainDart = File('$clientDir/lib/main.dart');
            if (mainDart.existsSync()) {
              try {
                mainDart.setLastModifiedSync(now);
              } catch (_) {}
            }

            // Wait a brief moment to ensure filesystem change is registered
            Future.delayed(const Duration(milliseconds: 150), () {
              process.stdin.write(action);
            });
          }

          // Trigger quit once reload/restart is done
          if (commandSent) {
            if (action == 'r' && trimmed.contains('Reloaded ')) {
              actionCompleted = true;
              process.stdin.write('q');
            } else if (action == 'R' &&
                trimmed.contains('Restarted application')) {
              actionCompleted = true;
              process.stdin.write('q');
            }
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );

  process.stderr.transform(utf8.decoder).listen(stderr.write);

  // Safety timers to prevent hanging if stdout patterns don't match
  final safetyTimer1 = Timer(const Duration(seconds: 8), () {
    if (!commandSent) {
      commandSent = true;
      process.stdin.write(action);
    }
  });

  final safetyTimer2 = Timer(const Duration(seconds: 13), () {
    if (!completer.isCompleted) {
      process.stdin.write('q');
    }
  });

  await completer.future;
  safetyTimer1.cancel();
  safetyTimer2.cancel();
  final processExitCode = await process.exitCode;
  if (processExitCode != 0 || !actionCompleted) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} failed'
      '${processExitCode == 0 ? '' : ' (Flutter exited with code $processExitCode)'}.',
    );
    exitCode = processExitCode == 0 ? 1 : processExitCode;
  }
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
      interactiveHint: '--- Agent logs (r/R: restart, s/q: safe stop, Ctrl+C: close logs) ---',
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

Future<void> handleAgentRestart(
  int? portOverride, {
  bool force = false,
  int timeoutSeconds = 60,
  String? sanadHomePath,
}) async {
  final instance = await selectAgentInstance(
    portOverride,
    allowStartupGrace: true,
    sanadHomePath: sanadHomePath,
  );
  if (instance == null) exit(1);
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final workspaceHash = runtime.worktreeId.split('-').last;
  if (instance.workspaceHash != workspaceHash) {
    stderr.writeln(
      'Agent restart aborted: port ${instance.port} belongs to workspace '
      '${instance.workspaceHash}, not ${runtime.worktreeId}. Explicit ports '
      'are diagnostic selectors and do not grant mutation ownership.',
    );
    exitCode = 1;
    return;
  }
  final clients = await discoverClientInstances();
  final processState = selectRuntimeProcessState(
    activeAgents: [instance],
    activeClients: clients,
    runtime: runtime,
    requestedAgentPort: instance.port,
  );
  final activeHome = resolveActiveSanadHome(runtime, processState);
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: processState,
    sanadHome: activeHome,
  );
  if (!ownership.isManaged) {
    stderr.writeln(
      'Agent restart aborted: runtime class is '
      '${ownership.classification.name}; a live matching sanad-dev launcher '
      'lease is required.',
    );
    exitCode = 1;
    return;
  }

  print(
    'Sending restart request to local agent daemon on port ${instance.port}...',
  );
  final client = HttpClient();
  try {
    final restartUri = Uri.parse('http://localhost:${instance.port}/restart')
        .replace(
          queryParameters: {
            'force': force.toString(),
            'timeout_seconds': timeoutSeconds.toString(),
          },
        );
    final request = await client.postUrl(restartUri);
    await authorizeLocalGatewayRequest(request, activeHome);
    final requesterSessionId =
        Platform.environment['SANAD_REQUESTER_SESSION_ID'];
    final requesterToolCallId =
        Platform.environment['SANAD_REQUESTER_TOOL_CALL_ID'];
    if (requesterSessionId?.isNotEmpty == true) {
      request.headers.set('x-sanad-requester-session-id', requesterSessionId!);
    }
    if (requesterToolCallId?.isNotEmpty == true) {
      request.headers.set(
        'x-sanad-requester-tool-call-id',
        requesterToolCallId!,
      );
    }
    final response = await request.close().timeout(
      Duration(seconds: timeoutSeconds + 5),
    );
    final body = await response.transform(utf8.decoder).join();
    Map<String, dynamic>? data;
    try {
      final decoded = json.decode(body);
      if (decoded is Map) {
        data = Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      // Handled below as a failed restart response.
    }
    final responseData = data;
    if (response.statusCode == 200 && responseData?['success'] == true) {
      print('✓ Daemon Response: ${responseData?['message'] ?? body}');
      print(
        'Waiting for local agent daemon on port ${instance.port} to complete restart...',
      );
      final healthy = await _waitForAgentHealthPort(
        instance.port,
        workspaceHash,
        activeHome,
        timeout: Duration(seconds: timeoutSeconds),
      );
      if (healthy) {
        print('✓ Agent daemon restarted and healthy on port ${instance.port}.');
      } else {
        stderr.writeln(
          'Restart failed: daemon accepted the request, but the health probe '
          'timed out on port ${instance.port} after ${timeoutSeconds}s.',
        );
        exitCode = 1;
      }
    } else {
      stderr.writeln(
        'Restart failed: '
        '${data?['message'] ?? (body.isEmpty ? 'HTTP ${response.statusCode}' : 'invalid daemon response')}',
      );
      final blockers = data?['blockers'];
      if (blockers != null) stderr.writeln('Blockers: $blockers');
      exitCode = 1;
    }
  } catch (e) {
    stderr.writeln(
      'Could not connect to local agent daemon at http://localhost:${instance.port}: $e',
    );
    exitCode = 1;
  } finally {
    client.close();
  }
}

Future<void> handleClientDevTools(int? portOverride) async {
  final instance = await selectClientInstance(portOverride);
  if (instance == null) exit(1);

  final vmUrl = instance.token.isEmpty
      ? 'http://127.0.0.1:${instance.port}'
      : 'http://127.0.0.1:${instance.port}/${instance.token}';

  print('Opening Flutter DevTools for client on port ${instance.port}...');
  print('VM Service URL: $vmUrl');

  if (Platform.isMacOS) {
    try {
      final pbcopy = await Process.start('pbcopy', []);
      pbcopy.stdin.write(vmUrl);
      await pbcopy.stdin.close();
      print('📋 VM Service URL copied to clipboard!');
    } catch (_) {}
  }

  print('\n💡 Tip: To attach VS Code debugger to this running instance:');
  print('   1. Open the Run & Debug panel in VS Code.');
  print('   2. Select "Attach to Running Client" and click play.');
  print('   3. Paste the copied URL and press Enter.\n');

  final process = await Process.start(Platform.resolvedExecutable, [
    'devtools',
    vmUrl,
  ], mode: ProcessStartMode.inheritStdio);

  final exitCode = await process.exitCode;
  exit(exitCode);
}

Future<void> handleUiDriverCommand(List<String> args) async {
  final callerDir =
      Platform.environment['SANAD_DEV_CALLER_DIR'] ?? Directory.current.path;
  final runtime = await discoverSanadDevRuntime(callerDirectory: callerDir);
  final repoRoot = runtime.repositoryRoot;
  final clientDir = Directory('$repoRoot/client');
  final toolScript = '$repoRoot/scripts/flutter_driver_cli.dart';

  final hasExplicitVmUrl = args.any(
    (arg) =>
        arg == '--vm-url' ||
        arg == '-u' ||
        arg.startsWith('--vm-url=') ||
        arg.startsWith('-u='),
  );
  final isHelpRequest =
      args.isEmpty ||
      args.first == 'help' ||
      args.any((arg) => arg == '-h' || arg == '--help');
  final extraArgs = <String>[];
  if (!hasExplicitVmUrl && !isHelpRequest) {
    final activeClients = await discoverClientInstances();
    final processState = selectRuntimeProcessState(
      activeAgents: await discoverAgentInstances(),
      activeClients: activeClients,
      runtime: runtime,
    );
    final activeHome = resolveActiveSanadHome(runtime, processState);
    final ownership = await assessRuntimeOwnership(
      runtime: runtime,
      state: processState,
      sanadHome: activeHome,
    );
    final managedClients = ownership.isManaged
        ? ownership.state.ownedClients
        : const <ClientInstance>[];
    if (managedClients.length != 1) {
      stderr.writeln(
        managedClients.isEmpty
            ? 'No active driver-enabled client is managed for this worktree. '
                  'Run `sanad-dev run --driver` first or pass --vm-url explicitly.'
            : 'Multiple managed clients are active for this worktree. '
                  'Pass --vm-url explicitly to select one.',
      );
      exitCode = 1;
      return;
    }
    final selectedClient = managedClients.single;
    final tokenPath = selectedClient.token.isEmpty
        ? ''
        : '${selectedClient.token}/';
    extraArgs.addAll([
      '--vm-url',
      'http://127.0.0.1:${selectedClient.port}/$tokenPath',
    ]);
  }

  final process = await Process.start(
    'fvm',
    [
      'dart',
      '--packages=${clientDir.path}/.dart_tool/package_config.json',
      toolScript,
      ...args,
      ...extraArgs,
    ],
    workingDirectory: clientDir.path,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
    environment: {...Platform.environment, 'SANAD_DEV_CALLER_DIR': callerDir},
  );

  final code = await process.exitCode;
  exit(code);
}
