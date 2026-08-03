import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';

/// A thin helper that reads and updates the Sanad `.env` file while preserving
/// comments and unknown keys. Only the targeted keys are mutated.
///
/// API keys for simple providers live here (per the plan's storage rules).
/// OAuth tokens live in `ProviderCredentialStore`.
class EnvFileService {
  late final String _envPath;
  late final bool _usesSanadHome;

  EnvFileService({String? envPath}) {
    _usesSanadHome = envPath == null;
    _envPath = envPath ?? getEnvPath();
  }

  String get envPath => _envPath;

  /// Reads the current `.env` into a string-keyed map (comments stripped).
  Map<String, String> readAll() {
    final file = File(_envPath);
    final boundary = SanadHomeBootstrap.identity();
    if (_usesSanadHome ? !boundary.fileExists('.env') : !file.existsSync()) {
      return <String, String>{};
    }
    final map = <String, String>{};
    final lines = _usesSanadHome
        ? utf8.decode(boundary.readSecretBytes('.env')).split('\n')
        : file.readAsLinesSync();
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final idx = trimmed.indexOf('=');
      if (idx <= 0) continue;
      final key = trimmed.substring(0, idx).trim();
      final value = trimmed.substring(idx + 1).trim();
      map[key] = value;
    }
    return map;
  }

  /// Returns the value for [key] or [defaultValue] when missing.
  String get(String key, {String defaultValue = ''}) {
    return readAll()[key] ?? defaultValue;
  }

  /// Merges [updates] into the `.env` file, preserving comments and any keys
  /// not present in [updates]. Keys with empty values are removed.
  Future<void> upsert(Map<String, String> updates) async {
    final file = File(_envPath);
    if (!_usesSanadHome && !file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }

    final existingLines = file.existsSync()
        ? file.readAsLinesSync()
        : const <String>[];

    final writtenKeys = <String>{};
    final output = <String>[];

    for (final line in existingLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        output.add(line);
        continue;
      }
      final idx = trimmed.indexOf('=');
      if (idx <= 0) {
        output.add(line);
        continue;
      }
      final key = trimmed.substring(0, idx).trim();
      if (updates.containsKey(key)) {
        final value = updates[key]!;
        if (value.isNotEmpty) {
          output.add('$key=$value');
          writtenKeys.add(key);
        }
        // empty value -> drop the line (remove)
      } else {
        output.add(line);
      }
    }

    for (final entry in updates.entries) {
      if (entry.value.isEmpty) continue;
      if (writtenKeys.contains(entry.key)) continue;
      output.add('${entry.key}=${entry.value}');
    }

    final content = '${output.join('\n')}\n';
    if (_usesSanadHome) {
      await SanadHomeBootstrap.identity().writeConfigText('.env', content);
    } else {
      await file.writeAsString(content);
    }
  }

  /// Removes the given keys from the `.env` file.
  Future<void> removeKeys(Iterable<String> keys) async {
    final removeSet = keys.toSet();
    final file = File(_envPath);
    final boundary = SanadHomeBootstrap.identity();
    if (_usesSanadHome ? !boundary.fileExists('.env') : !file.existsSync()) {
      return;
    }

    final existingLines = _usesSanadHome
        ? utf8.decode(boundary.readSecretBytes('.env')).split('\n')
        : file.readAsLinesSync();
    final output = <String>[];

    for (final line in existingLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        output.add(line);
        continue;
      }
      final idx = trimmed.indexOf('=');
      if (idx <= 0) {
        output.add(line);
        continue;
      }
      final key = trimmed.substring(0, idx).trim();
      if (!removeSet.contains(key)) {
        output.add(line);
      }
    }

    final content = '${output.join('\n')}\n';
    if (_usesSanadHome) {
      await boundary.writeConfigText('.env', content);
    } else {
      await file.writeAsString(content);
    }
  }
}
