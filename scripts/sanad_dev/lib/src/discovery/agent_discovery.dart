part of '../../sanad_dev_cli.dart';

class AgentInstance {
  final int port;
  final String workspaceHash;
  final String stateMode;
  final bool gatewayEnabled;
  final String? launcherId;
  final String? runtimeNonce;
  final String? sanadHome;
  AgentInstance(
    this.port,
    this.workspaceHash,
    this.stateMode, {
    this.gatewayEnabled = false,
    this.launcherId,
    this.runtimeNonce,
    this.sanadHome,
  });
}

Future<List<AgentInstance>> discoverAgentInstances({
  String? sanadHomeOverride,
  SanadDevRuntime? runtime,
}) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(milliseconds: 150);
  final instances = <AgentInstance>[];
  final activeRuntime =
      runtime ??
      await discoverSanadDevRuntime(
        callerDirectory: _callerDirectory,
        sanadHomeOverride: sanadHomeOverride,
      );
  final candidateHomes = await discoverLocalGatewayCandidateHomes(
    activeRuntime,
    sanadHomeOverride: sanadHomeOverride,
  );
  final credentials = <({String home, String value})>[];
  for (final home in candidateHomes) {
    try {
      credentials.add((
        home: home,
        value: await readLocalGatewayCredential(home),
      ));
    } on LocalGatewayCredentialUnavailable {
      // A runtime without a started daemon may not have generated a token yet.
    }
  }
  final credentialCounts = <String, int>{};
  for (final credential in credentials) {
    credentialCounts.update(
      credential.value,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }
  credentials.removeWhere(
    (credential) => credentialCounts[credential.value] != 1,
  );

  final futures = <Future>[];
  // Scan the default and worktree allocation range.
  for (int port = 58085; port <= 58185; port++) {
    futures.add(() async {
      for (final credential in credentials) {
        try {
          final request = await client.getUrl(
            Uri.parse('http://localhost:$port/health'),
          );
          request.headers.set(localGatewayCredentialHeader, credential.value);
          final response = await request.close().timeout(
            const Duration(milliseconds: 150),
          );
          if (response.statusCode == 200) {
            final body = await response.transform(utf8.decoder).join();
            final data = json.decode(body);
            if (data['status'] == 'ok') {
              final workspaceHash =
                  data['workspace_hash'] as String? ?? 'unknown';
              final stateMode = data['state_mode'] as String? ?? 'default';
              final gatewayEnabled = data['gateway_enabled'] == true;
              instances.add(
                AgentInstance(
                  port,
                  workspaceHash,
                  stateMode,
                  gatewayEnabled: gatewayEnabled,
                  launcherId: data['dev_launcher_id'] as String?,
                  runtimeNonce: data['dev_runtime_nonce'] as String?,
                  sanadHome: credential.home,
                ),
              );
              return;
            }
          } else {
            await response.drain();
          }
        } catch (_) {}
      }
    }());
  }
  await Future.wait(futures);
  client.close(force: true);
  return instances;
}

Future<String?> inferPostLaunchSanadHome(SanadDevRuntime runtime) async {
  try {
    final activeAttempt = await readLocatedSanadDevStartupAttempt(
      runtimeDirectory: runtime.runtimeDirectory,
      workspaceHash: runtime.worktreeId.split('-').last,
    );
    final home = activeAttempt?.resolvedHome;
    return home != null && isAbsoluteFileSystemPath(home) ? home : null;
  } on Object {
    return null;
  }
}

Future<Set<String>> discoverLocalGatewayCandidateHomes(
  SanadDevRuntime runtime, {
  String? sanadHomeOverride,
}) async {
  final explicitHome = sanadHomeOverride?.trim();
  if (explicitHome != null && explicitHome.isNotEmpty) {
    return {runtime.sanadHome};
  }

  final primaryHome = resolveDefaultUserSanadHome(Platform.environment);
  final homes = <String>{runtime.sanadHome, primaryHome};
  final inferredHome = await inferPostLaunchSanadHome(runtime);
  if (inferredHome != null) homes.add(inferredHome);

  final linkedHomes = Directory(
    '$primaryHome${Platform.pathSeparator}dev${Platform.pathSeparator}homes',
  );
  if (await linkedHomes.exists()) {
    await for (final entity in linkedHomes.list(followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        homes.add(entity.path);
      }
    }
  }

  final runtimeRoot = Directory(runtime.runtimeDirectory).parent;
  if (await runtimeRoot.exists()) {
    await for (final entity in runtimeRoot.list(followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      final metadata = File(
        '${entity.path}${Platform.pathSeparator}runtime.json',
      );
      try {
        final decoded = jsonDecode(
          await secureRuntimeReadText(entity.path, metadata.path),
        );
        if (decoded is Map) {
          final home = decoded['sanad_home']?.toString().trim();
          if (home != null && home.isNotEmpty) homes.add(home);
        }
      } on Object {
        // Stale, missing, or unsafe metadata cannot grant discovery access.
      }
    }
  }
  return homes;
}
