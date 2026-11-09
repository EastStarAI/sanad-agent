part of '../../../sanad_dev_cli.dart';

/// Waits for any Agent serving [workspaceHash] on [port].
///
/// This is the identity-free wait used by flows that deliberately adopt an
/// unmanaged Agent (takeover). A managed restart must not use it: it proves only
/// that *some* Agent for the source answers, which is how a foreign daemon was
/// once reported as a successful restart. `waitForRestartedAgentIdentity` adds
/// the lease identity that a restart has to prove.
Future<bool> _waitForAgentHealthPort(
  int port,
  String workspaceHash,
  String sanadHome, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final decoded = await readAgentHealthDocument(port, sanadHome);
    if (decoded != null && decoded['workspace_hash'] == workspaceHash) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return false;
}

Future<int> _nextAvailableVmServicePort(int preferred) async {
  for (var offset = 0; offset < 1000; offset++) {
    final candidate = 51000 + ((preferred - 51000 + offset) % 1000);
    if (!await _vmServiceIsAvailable(candidate)) return candidate;
  }
  throw StateError('No free Flutter VM-service port is available.');
}

Future<bool> _vmServiceIsAvailable(int port) async {
  try {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
    ).timeout(const Duration(milliseconds: 300));
    await socket.close();
    return true;
  } on Object {
    return false;
  }
}

Future<bool> _waitForAgentPortToStop(int port, String sanadHome) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    final http = HttpClient();
    try {
      final request = await http.getUrl(
        Uri.parse('http://127.0.0.1:$port/health'),
      );
      await authorizeLocalGatewayRequest(request, sanadHome);
      final response = await request.close().timeout(
        const Duration(milliseconds: 150),
      );
      await response.drain<void>();
    } on Object {
      return true;
    } finally {
      http.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
}

Future<bool> _waitForAgent(
  SanadDevRuntime runtime, {
  required String launcherId,
  required String runtimeNonce,
  bool Function()? shouldAbort,
}) async {
  final client = HttpClient();
  try {
    return await waitForSanadDevStartupProbe(
      shouldAbort: shouldAbort,
      probe: () async {
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${runtime.agentPort}/health'),
          );
          await authorizeLocalGatewayRequest(request, runtime.sanadHome);
          final response = await request.close().timeout(
            const Duration(milliseconds: 500),
          );
          final body = await response.transform(utf8.decoder).join();
          if (response.statusCode == 200 &&
              matchesSanadDevAgentHealth(
                jsonDecode(body),
                launcherId: launcherId,
                runtimeNonce: runtimeNonce,
              )) {
            return true;
          }
        } catch (_) {}
        return false;
      },
    );
  } finally {
    client.close(force: true);
  }
}
