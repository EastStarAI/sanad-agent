part of '../../sanad_dev_cli.dart';

bool _agentInteractiveRestartInProgress = false;

Future<void> _sendManagedAgentInteractiveKey({
  required String sanadHome,
  required int agentPort,
  required String key,
}) async {
  if (key == 'r' || key == 'R') {
    if (_agentInteractiveRestartInProgress) {
      print('\n[sanad-dev] Agent restart already in progress, ignoring key.');
      return;
    }
    _agentInteractiveRestartInProgress = true;
    try {
      await handleAgentRestart(agentPort, exitOnError: false);
    } finally {
      _agentInteractiveRestartInProgress = false;
    }
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

Future<bool> handleAgentRestart(
  int? portOverride, {
  bool force = false,
  int timeoutSeconds = 60,
  String? sanadHomePath,
  bool exitOnError = true,
}) async {
  final instance = await selectAgentInstance(
    portOverride,
    allowStartupGrace: true,
    sanadHomePath: sanadHomePath,
    exitOnError: exitOnError,
  );
  if (instance == null) {
    if (exitOnError) exit(1);
    return false;
  }
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
    if (exitOnError) exitCode = 1;
    return false;
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
    if (exitOnError) exitCode = 1;
    return false;
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
        return true;
      } else {
        stderr.writeln(
          'Restart failed: daemon accepted the request, but the health probe '
          'timed out on port ${instance.port} after ${timeoutSeconds}s.',
        );
        if (exitOnError) exitCode = 1;
        return false;
      }
    } else {
      stderr.writeln(
        'Restart failed: '
        '${data?['message'] ?? (body.isEmpty ? 'HTTP ${response.statusCode}' : 'invalid daemon response')}',
      );
      final blockers = data?['blockers'];
      if (blockers != null) stderr.writeln('Blockers: $blockers');
      if (exitOnError) exitCode = 1;
      return false;
    }
  } on Object catch (e) {
    stderr.writeln('Agent restart request failed: $e');
    if (exitOnError) exitCode = 1;
    return false;
  } finally {
    client.close(force: true);
  }
}
