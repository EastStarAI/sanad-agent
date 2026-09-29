import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/models/client_cli_exceptions.dart';
import '../domain/models/client_cli_record.dart';
import 'client_cli_home_resolver.dart';
import 'client_cli_ownership.dart';

class ClientCliDiscovery {
  final ClientCliHomeResolver homeResolver;
  final ClientCliOwnership ownership;
  final http.Client Function()? clientFactory;

  const ClientCliDiscovery({
    this.homeResolver = const ClientCliHomeResolver(),
    this.ownership = const ClientCliOwnership(),
    this.clientFactory,
  });

  /// Discovers the active and verified Client CLI host endpoint.
  /// Enforces deterministic no-owner, disabled, ambiguous, and version-mismatch errors.
  Future<ClientCliRecord> discover({
    String? explicitHome,
    Map<String, String>? environment,
    String? expectedCliVersion,
  }) async {
    final sanadHome = homeResolver.resolveSanadHome(
      explicitHome: explicitHome,
      environment: environment,
    );

    final record = await ownership.readRecord(sanadHome, verifyPermissions: true);
    if (record == null) {
      throw ClientCliNoOwnerException(sanadHome);
    }

    final alive = await ownership.isProcessAlive(record.pid);
    if (!alive) {
      // Stale owner cleanup
      await ownership.releaseOwnership(sanadHome, pid: record.pid);
      throw ClientCliNoOwnerException(sanadHome);
    }

    if (!record.enabled) {
      throw ClientCliDisabledException(sanadHome);
    }

    // Verify health and version via loopback HTTP probe
    final httpClient = clientFactory != null ? clientFactory!() : http.Client();
    try {
      final uri = Uri.parse('http://127.0.0.1:${record.port}/health');
      final response = await httpClient.get(
        uri,
        headers: {
          'x-sanad-client-token': record.token,
          'authorization': 'Bearer ${record.token}',
        },
      ).timeout(const Duration(milliseconds: 1000));

      if (response.statusCode != 200) {
        throw ClientCliNoOwnerException(sanadHome);
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final isServerEnabled = data['enabled'] == true;
      if (!isServerEnabled) {
        throw ClientCliDisabledException(sanadHome);
      }

      final serverClientVersion = data['client_version']?.toString() ?? record.clientVersion;
      if (expectedCliVersion != null &&
          expectedCliVersion.isNotEmpty &&
          serverClientVersion != 'unknown' &&
          expectedCliVersion != 'unknown') {
        final serverMajor = serverClientVersion.split('.').first;
        final cliMajor = expectedCliVersion.split('.').first;
        if (serverMajor != cliMajor) {
          throw ClientCliVersionMismatchException(
            clientVersion: serverClientVersion,
            cliVersion: expectedCliVersion,
          );
        }
      }

      return record;
    } on ClientCliException {
      rethrow;
    } catch (_) {
      throw ClientCliNoOwnerException(sanadHome);
    } finally {
      httpClient.close();
    }
  }
}
