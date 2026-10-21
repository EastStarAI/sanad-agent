import 'package:sanad_agent/capabilities/permissions/child_process_security_contract.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';

/// Owner of user secrets acquired through `system_request_secret` (Plan 84).
///
/// Entries live only in the Agent vault's `custom:` namespace, keyed by their
/// environment variable name. Nothing here returns a value to a model-visible
/// surface: [resolve] exists only for the shell backend that injects the
/// explicitly requested names into one child process.
class UserSecretVault {
  UserSecretVault({SecretVaults? Function()? vaults})
    : _vaults = vaults ?? (() => SecretVaults.current);

  final SecretVaults? Function() _vaults;

  static final _namePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');

  /// Upper bound for one stored value.
  static const maxValueLength = 16384;

  /// Why [name] cannot name a user secret: `invalid_name` when it is not a
  /// portable environment name, `reserved_name` when it would replace a
  /// protected operator variable or reintroduce a Sanad credential. `null`
  /// when it is acceptable.
  static String? nameRejection(String name) {
    if (!_namePattern.hasMatch(name)) return 'invalid_name';
    if (ChildProcessSecurityContract.isDangerousRequestOverride(name)) {
      return 'reserved_name';
    }
    return null;
  }

  SecretVaultNamespace? get _namespace => _vaults()?.custom;

  /// Whether the platform vault can store user secrets now.
  bool get available => _vaults()?.available ?? false;

  /// Stored secret names, sorted. Never values.
  List<String> names() => (_namespace?.ids.toList() ?? <String>[])..sort();

  /// Writes [entries] with read-back verification. Throws when the vault is
  /// unavailable or verification fails; nothing is written to any file.
  Future<void> store(Map<String, String> entries) async {
    final vaults = _vaults();
    if (vaults == null) {
      throw StateError('The Agent credential vault is not open.');
    }
    for (final name in entries.keys) {
      if (nameRejection(name) != null) {
        throw ArgumentError.value(name, 'name', 'not a valid secret name');
      }
    }
    await vaults.put(vaults.custom, entries);
  }

  /// Deletes [names]; returns the names that existed.
  Future<List<String>> remove(Iterable<String> names) async {
    final vaults = _vaults();
    if (vaults == null) return const [];
    final existing = vaults.custom.ids.toSet();
    final targets = [
      for (final name in names.toSet())
        if (existing.contains(name)) name,
    ]..sort();
    await vaults.remove(vaults.custom, targets);
    return targets;
  }

  /// Values for exactly [names]; unknown names are reported in `missing`.
  ({Map<String, String> values, List<String> missing}) resolve(
    Iterable<String> names,
  ) {
    final namespace = _namespace;
    final values = <String, String>{};
    final missing = <String>[];
    for (final name in names.toSet()) {
      final value = namespace?.read(name);
      if (value == null) {
        missing.add(name);
      } else {
        values[name] = value;
      }
    }
    missing.sort();
    return (values: values, missing: missing);
  }
}

/// Replaces injected secret values in command output before it becomes a
/// tool result, progress checkpoint, history row or request dump.
///
/// This catches verbatim echoes only. A command that transforms a value
/// (encoding, splitting, reversing) is not detected.
class SecretOutputRedactor {
  SecretOutputRedactor(Map<String, String> secrets)
    : _entries = [
        for (final entry in secrets.entries)
          if (entry.value.isNotEmpty) (name: entry.key, value: entry.value),
      ]..sort((a, b) => b.value.length.compareTo(a.value.length));

  const SecretOutputRedactor.none() : _entries = const [];

  final List<({String name, String value})> _entries;

  bool get isEmpty => _entries.isEmpty;

  String redact(String text) {
    var out = text;
    for (final entry in _entries) {
      out = out.replaceAll(entry.value, '[REDACTED:${entry.name}]');
    }
    return out;
  }
}
