import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:sanad_agent/core/auth/agent_secret_namespaces.dart';
import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:uuid/uuid.dart';

class McpSecretStore {
  McpSecretStore({
    String? homeDirectoryPath,
    AgentSecretStore? agentSecretStore,
  }) : _boundary = SanadHomeBootstrap.atRoot(
         homeDirectoryPath?.trim().isNotEmpty == true
             ? homeDirectoryPath!.trim()
             : getSanadHome(),
         scope: SanadHomeScope.identity,
       ),
       _agentSecretStore = agentSecretStore;

  static const _fileName = 'mcp_secrets.json';
  static const _prefix = 'mcp-secret://';
  final SanadHomeBootstrap _boundary;
  final AgentSecretStore? _agentSecretStore;
  final Map<String, String> _cache = {};
  final _logger = Logger('McpSecretStore');

  /// Migrates legacy `mcp_secrets.json` into [_agentSecretStore] under
  /// the `mcp:` namespace.
  ///
  /// Verification guarantee: Each secret is written to the target vault, read back,
  /// and compared. Only if ALL secrets pass verification is the legacy file removed.
  Future<bool> migrateLegacy({bool deleteOnSuccess = true}) async {
    final vault = _agentSecretStore;
    if (vault == null) return false;

    if (!_boundary.fileExists(_fileName)) {
      // Nothing to migrate
      return true;
    }

    final secrets = _readAll();
    if (secrets.isEmpty) {
      if (deleteOnSuccess && _boundary.fileExists(_fileName)) {
        _boundary.deleteFileSync(_fileName);
      }
      return true;
    }

    final verifiedEntries = <String, String>{};
    final migratedRefs = <String>[];

    for (final entry in secrets.entries) {
      final ref = entry.key;
      final value = entry.value;

      try {
        final key = AgentSecretNamespaces.mcpKey(ref);
        await vault.write(key, value);

        // Read-back verification
        final readBack = await vault.read(key);
        if (readBack != value) {
          _logger.severe('Migration failed for MCP secret $ref: verification mismatch');
          return false;
        }

        verifiedEntries[ref] = value;
        migratedRefs.add(ref);
      } catch (e) {
        _logger.severe('Migration failed for MCP secret $ref: $e');
        return false;
      }
    }

    try {
      await vault.write(
        AgentSecretNamespaces.mcpIndexKey,
        jsonEncode(migratedRefs),
      );
    } catch (e) {
      _logger.warning('Failed to write MCP index during migration: $e');
    }

    _cache.addAll(verifiedEntries);

    if (deleteOnSuccess) {
      try {
        if (_boundary.fileExists(_fileName)) {
          _boundary.deleteFileSync(_fileName);
        }
        _logger.info('Legacy mcp_secrets.json successfully migrated to vault and deleted.');
      } catch (e) {
        _logger.warning('Failed to delete legacy mcp_secrets.json after migration: $e');
      }
    }

    return true;
  }

  Future<String> put(String value, {String? existingRef}) async {
    if (value.isEmpty) throw const FormatException('Secret value is required.');
    final reference = isReference(existingRef)
        ? existingRef!
        : '$_prefix${const Uuid().v4()}';

    _cache[reference] = value;

    if (_agentSecretStore != null) {
      final key = AgentSecretNamespaces.mcpKey(reference);
      await _agentSecretStore.write(key, value);
      final readBack = await _agentSecretStore.read(key);
      if (readBack != value) {
        throw StateError('MCP secret verification failed.');
      }
      try {
        await _agentSecretStore.write(
          AgentSecretNamespaces.mcpIndexKey,
          jsonEncode(_cache.keys.toList()),
        );
      } catch (_) {}
    } else {
      final secrets = _readAll();
      secrets[reference] = value;
      await _writeAll(secrets);
      if (_readAll()[reference] != value) {
        throw StateError('MCP secret verification failed.');
      }
    }

    return reference;
  }

  String? resolve(String? reference) {
    if (!isReference(reference)) return null;
    if (_cache.containsKey(reference)) {
      return _cache[reference];
    }
    return _readAll()[reference];
  }

  Future<void> remove(String? reference) async {
    if (!isReference(reference)) return;
    _cache.remove(reference);

    if (_agentSecretStore != null) {
      await _agentSecretStore.delete(AgentSecretNamespaces.mcpKey(reference!));
      try {
        await _agentSecretStore.write(
          AgentSecretNamespaces.mcpIndexKey,
          jsonEncode(_cache.keys.toList()),
        );
      } catch (_) {}
    } else {
      final secrets = _readAll();
      if (secrets.remove(reference) != null) await _writeAll(secrets);
    }
  }

  Future<Map<String, String>> putMany(
    Map<String, String> values, {
    Map<String, String> existingRefs = const {},
  }) async {
    if (values.isEmpty) return const {};
    final references = <String, String>{};

    for (final entry in values.entries) {
      if (entry.value.isEmpty) {
        throw FormatException('Secret value for ${entry.key} is required.');
      }
      final existing = existingRefs[entry.key];
      final reference = isReference(existing)
          ? existing!
          : '$_prefix${const Uuid().v4()}';
      references[entry.key] = reference;
      _cache[reference] = entry.value;

      if (_agentSecretStore != null) {
        final key = AgentSecretNamespaces.mcpKey(reference);
        await _agentSecretStore.write(key, entry.value);
        final readBack = await _agentSecretStore.read(key);
        if (readBack != entry.value) {
          throw StateError('MCP secret verification failed.');
        }
      }
    }

    if (_agentSecretStore != null) {
      try {
        await _agentSecretStore.write(
          AgentSecretNamespaces.mcpIndexKey,
          jsonEncode(_cache.keys.toList()),
        );
      } catch (_) {}
    } else {
      final secrets = _readAll();
      for (final entry in references.entries) {
        secrets[entry.value] = values[entry.key]!;
      }
      await _writeAll(secrets);
      final verified = _readAll();
      for (final entry in references.entries) {
        if (verified[entry.value] != values[entry.key]) {
          throw StateError('MCP secret verification failed.');
        }
      }
    }

    return references;
  }

  Map<String, String> resolveMany(Map<String, String> references) {
    final result = <String, String>{};
    for (final entry in references.entries) {
      final resolved = resolve(entry.value);
      if (resolved != null) {
        result[entry.key] = resolved;
      }
    }
    return result;
  }

  static bool isReference(String? value) =>
      value != null && value.startsWith(_prefix);

  Map<String, String> _readAll() {
    if (!_boundary.fileExists(_fileName)) return <String, String>{};
    final bytes = _boundary.readSecretBytes(_fileName);
    if (bytes.isEmpty) return <String, String>{};
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('MCP secret store is invalid.');
    }
    return decoded.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
  }

  Future<void> _writeAll(Map<String, String> secrets) {
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(secrets),
    );
    return _boundary.writeSecretBytes(_fileName, bytes);
  }
}
