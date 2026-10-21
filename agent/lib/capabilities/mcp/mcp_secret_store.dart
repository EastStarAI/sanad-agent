import 'dart:convert';

import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:uuid/uuid.dart';

/// MCP secret values addressed by opaque `mcp-secret://` references.
///
/// When this process opened the Agent vault for the Home (daemon and CLI
/// startup), values live in its `mcp:` namespace. A Home this process never
/// opened (temporary test or tool Homes) keeps the legacy owner-only file.
class McpSecretStore {
  McpSecretStore({String? homeDirectoryPath})
    : _homePath = homeDirectoryPath?.trim().isNotEmpty == true
          ? homeDirectoryPath!.trim()
          : getSanadHome(),
      _boundary = SanadHomeBootstrap.atRoot(
        homeDirectoryPath?.trim().isNotEmpty == true
            ? homeDirectoryPath!.trim()
            : getSanadHome(),
        scope: SanadHomeScope.identity,
      );

  final String _homePath;

  SecretVaults? get _vault => SecretVaults.forHome(_homePath);

  static const _fileName = 'mcp_secrets.json';
  static const _prefix = 'mcp-secret://';
  final SanadHomeBootstrap _boundary;

  Future<String> put(String value, {String? existingRef}) async {
    if (value.isEmpty) throw const FormatException('Secret value is required.');
    final vault = _vault;
    if (vault != null) {
      final reference = isReference(existingRef)
          ? existingRef!
          : '$_prefix${const Uuid().v4()}';
      await vault.put(vault.mcp, {reference: value});
      return reference;
    }
    final secrets = _readAll();
    final reference = isReference(existingRef)
        ? existingRef!
        : '$_prefix${const Uuid().v4()}';
    secrets[reference] = value;
    await _writeAll(secrets);
    if (_readAll()[reference] != value) {
      throw StateError('MCP secret verification failed.');
    }
    return reference;
  }

  String? resolve(String? reference) {
    if (!isReference(reference)) return null;
    final vault = _vault;
    if (vault != null) return vault.mcp.read(reference!);
    return _readAll()[reference];
  }

  Future<void> remove(String? reference) async {
    if (!isReference(reference)) return;
    final vault = _vault;
    if (vault != null) return vault.remove(vault.mcp, [reference!]);
    final secrets = _readAll();
    if (secrets.remove(reference) != null) await _writeAll(secrets);
  }

  Future<Map<String, String>> putMany(
    Map<String, String> values, {
    Map<String, String> existingRefs = const {},
  }) async {
    if (values.isEmpty) return const {};
    final vault = _vault;
    if (vault != null) {
      final references = <String, String>{};
      final entries = <String, String>{};
      for (final entry in values.entries) {
        if (entry.value.isEmpty) {
          throw FormatException('Secret value for ${entry.key} is required.');
        }
        final existing = existingRefs[entry.key];
        final reference = isReference(existing)
            ? existing!
            : '$_prefix${const Uuid().v4()}';
        references[entry.key] = reference;
        entries[reference] = entry.value;
      }
      await vault.put(vault.mcp, entries);
      return references;
    }
    final secrets = _readAll();
    final references = <String, String>{};
    for (final entry in values.entries) {
      if (entry.value.isEmpty) {
        throw FormatException('Secret value for ${entry.key} is required.');
      }
      final existing = existingRefs[entry.key];
      final reference = isReference(existing)
          ? existing!
          : '$_prefix${const Uuid().v4()}';
      secrets[reference] = entry.value;
      references[entry.key] = reference;
    }
    await _writeAll(secrets);
    final verified = _readAll();
    for (final entry in references.entries) {
      if (verified[entry.value] != values[entry.key]) {
        throw StateError('MCP secret verification failed.');
      }
    }
    return references;
  }

  Map<String, String> resolveMany(Map<String, String> references) {
    final vault = _vault;
    if (vault != null) {
      return {
        for (final entry in references.entries)
          if (vault.mcp.read(entry.value) != null)
            entry.key: vault.mcp.read(entry.value)!,
      };
    }
    final secrets = _readAll();
    return {
      for (final entry in references.entries)
        if (secrets[entry.value] != null) entry.key: secrets[entry.value]!,
    };
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
