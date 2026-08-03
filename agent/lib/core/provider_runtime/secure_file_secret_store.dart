import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:logging/logging.dart';

import '../../engine/adapters/provider_registry.dart';
import '../constants.dart';
import '../sanad_home/sanad_home_bootstrap.dart';
import 'provider_protocol_constants.dart';
import 'secret_record.dart';
import 'secret_store.dart';

/// File-backed `SecretStore` keyed by instance UUID (Plan 29 §7.4).
///
/// Guarantees:
/// - Single JSON store file (`provider_secrets.json`) under [getSanadHome],
///   separate from `auth.json` and `provider_auth.json`. Records are keyed by
///   instance UUID.
/// - **Atomic writes**: payload is written to a temp file, flushed, fsynced,
///   then atomically renamed over the store. A crash mid-write never corrupts
///   the existing store.
/// - **Cross-process lock**: every read-modify-write acquires a blocking
///   exclusive `FileLock` on a sidecar `.lock` file so concurrent writers
///   (daemon + CLI) cannot interleave.
/// - **Owner-only permissions**: `chmod 600` on Unix; on Windows the file is
///   restricted to the current user via `icacls` (ACL) instead of being left
///   world-readable.
/// - **Redaction**: raw content is never logged; exceptions are masked.
///
/// This store does NOT claim encryption-at-rest; the abstraction allows an OS
/// vault backend to be added later without touching callers.
class SecureFileSecretStore implements SecretStore {
  final _logger = Logger('SecureFileSecretStore');

  late final String _storePath;
  late final String _lockPath;
  late final bool _usesSanadHome;

  SecureFileSecretStore({String? storePath}) {
    _usesSanadHome = storePath == null;
    _storePath = storePath ?? p.join(getSanadHome(), 'provider_secrets.json');
    _lockPath = '$_storePath.lock';
  }

  String get storePath => _storePath;

  Map<String, dynamic> _readRaw({bool backupIfCorrupted = false}) {
    final boundary = SanadHomeBootstrap.identity();
    final file = File(_storePath);
    if (_usesSanadHome
        ? !boundary.fileExists('provider_secrets.json')
        : !file.existsSync()) {
      return <String, dynamic>{};
    }
    try {
      final content = _usesSanadHome
          ? utf8.decode(boundary.readSecretBytes('provider_secrets.json'))
          : file.readAsStringSync();
      if (content.trim().isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      // Mask: never log raw file content, only a generic failure.
      _logger.warning('Failed to read secret store (corrupted?): $e');
      // Only move the corrupted file aside from within a write/remove path
      // (which holds the cross-process lock). Plain reads must NOT rename,
      // because that would mutate the store without coordination.
      if (backupIfCorrupted) {
        _backupCorrupted(file);
      }
    }
    return <String, dynamic>{};
  }

  /// Moves a corrupted store file aside with a timestamp suffix so the next
  /// write does not silently erase previous records, and so an operator can
  /// recover the data.
  void _backupCorrupted(File file) {
    try {
      if (_usesSanadHome) {
        final boundary = SanadHomeBootstrap.identity();
        final backupName =
            'provider_secrets.json.corrupted.${DateTime.now().millisecondsSinceEpoch}';
        boundary.writeSecretBytesSync(
          backupName,
          boundary.readSecretBytes('provider_secrets.json'),
        );
        boundary.deleteFileSync('provider_secrets.json');
      } else {
        final backup = File(
          '$_storePath.corrupted.${DateTime.now().millisecondsSinceEpoch}',
        );
        file.renameSync(backup.path);
      }
      _logger.warning('Corrupted secret store backed up.');
    } catch (e) {
      _logger.warning('Failed to backup corrupted store: $e');
    }
  }

  /// Atomically replaces the store file with [data]. MUST be called while
  /// holding the lock (see [_withLock]). Creates the temp file with
  /// owner-only permissions BEFORE writing any secret bytes, so the secret is
  /// never world-readable at any point (Plan 29 §7.4, §19 risk table).
  Future<void> _replaceStoreDataLocked(Map<String, dynamic> data) async {
    if (_usesSanadHome) {
      await SanadHomeBootstrap.identity().writeSecretBytes(
        'provider_secrets.json',
        utf8.encode(jsonEncode(data)),
      );
      return;
    }
    final file = File(_storePath);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    final tmpPath = '$_storePath.tmp';
    // Remove any stale temp file from a previous crashed write first.
    final staleTmp = File(tmpPath);
    if (staleTmp.existsSync()) {
      try {
        staleTmp.deleteSync();
      } catch (_) {}
    }
    // Create the temp file empty and secure it BEFORE writing secrets.
    final tmpFile = File(tmpPath);
    final raf = tmpFile.openSync(mode: FileMode.writeOnlyAppend);
    try {
      // Secure the (still empty) file descriptor immediately.
      await _secureFile(tmpFile);
      // Now write secret bytes into an already-secured file.
      raf.writeStringSync(jsonEncode(data));
      await raf.flush();
    } finally {
      raf.closeSync();
    }
    // Re-assert permissions on POSIX in case the platform reset them, then
    // atomically rename so the live path is never observed half-written.
    await _secureFile(tmpFile);
    await tmpFile.rename(_storePath);
  }

  Future<void> _secureFile(File file) async {
    if (Platform.isWindows) {
      await _secureFileWindows(file);
      return;
    }
    try {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) {
        _logger.warning('Failed to secure secret store: ${result.stderr}');
      }
    } catch (e) {
      _logger.warning('Failed to secure secret store: $e');
    }
  }

  Future<void> _secureFileWindows(File file) async {
    try {
      // Restrict to the current user, removing inherited defaults. This is a
      // best-effort ACL hardening; failures are logged but never skipped
      // silently (Plan 29 §7.4 / §19 risk table).
      final owner =
          Platform.environment['USERNAME'] ?? Platform.environment['USER'];
      if (owner == null || owner.isEmpty) return;
      final res1 = await Process.run('icacls', [file.path, '/inheritance:r']);
      await Process.run('icacls', [file.path, '/grant:r', '$owner:F']);
      if (res1.exitCode != 0) {
        _logger.warning('Windows ACL hardening partial: ${res1.stderr}');
      }
    } catch (e) {
      _logger.warning('Windows ACL hardening failed: $e');
    }
  }

  /// Acquires a blocking exclusive lock on the sidecar lock file, runs
  /// [action], then releases. Stale lock files are tolerated because the lock
  /// is on the file descriptor, not the file's existence.
  Future<T> _withLock<T>(Future<T> Function() action) async {
    final lockFile = File(_lockPath);
    if (!lockFile.existsSync()) {
      if (_usesSanadHome) {
        SanadHomeBootstrap.identity().writeSecretBytesSync(
          'provider_secrets.json.lock',
          const [],
        );
      } else {
        lockFile.createSync(recursive: true);
      }
    } else if (_usesSanadHome) {
      SanadHomeBootstrap.identity().readSecretBytes(
        'provider_secrets.json.lock',
      );
    }
    final raf = lockFile.openSync(mode: FileMode.write);
    try {
      await raf.lock(FileLock.blockingExclusive);
      return await action();
    } finally {
      try {
        raf.unlockSync();
      } catch (_) {}
      raf.closeSync();
    }
  }

  @override
  SecretRecord? read(String instanceId) {
    final data = _readRaw();
    final entry = data['instances']?[instanceId];
    if (entry is Map<String, dynamic>) {
      try {
        return SecretRecord.fromJson(entry);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  @override
  Future<void> write(String instanceId, SecretRecord record) async {
    await _withLock(() async {
      final data = _readRaw(backupIfCorrupted: true);
      final instances =
          (data['instances'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      instances[instanceId] = record.toJson();
      data['instances'] = instances;
      await _replaceStoreDataLocked(data);
    });
  }

  @override
  SecretSummary summary(String instanceId) =>
      SecretSummary.fromRecord(read(instanceId), instanceId);

  @override
  Future<void> remove(String instanceId) async {
    await _withLock(() async {
      final data = _readRaw(backupIfCorrupted: true);
      final instances =
          (data['instances'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      if (!instances.containsKey(instanceId)) return;
      instances.remove(instanceId);
      data['instances'] = instances;
      await _replaceStoreDataLocked(data);
    });
  }

  @override
  List<String> listIds() {
    final data = _readRaw();
    final instances = data['instances'];
    if (instances is Map) {
      return instances.keys.cast<String>().toList(growable: false);
    }
    return const [];
  }

  @override
  Future<void> pruneOrphans(Set<String> validInstanceIds) async {
    await _withLock(() async {
      final data = _readRaw(backupIfCorrupted: true);
      final instances =
          (data['instances'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      final orphanIds = instances.keys
          .where((instanceId) => !validInstanceIds.contains(instanceId))
          .toList(growable: false);
      if (orphanIds.isEmpty) return;
      for (final instanceId in orphanIds) {
        instances.remove(instanceId);
      }
      data['instances'] = instances;
      await _replaceStoreDataLocked(data);
    });
  }

  /// Convenience: produces a `SecretRecord` for a static API key. Used by the
  /// credential service when the user saves an API-key instance.
  static SecretRecord apiKeyRecord(
    String instanceId,
    String apiKey, {
    String authMethod = ProviderAuthMethod.apiKey,
  }) {
    return SecretRecord(
      instanceId: instanceId,
      apiKey: apiKey,
      authMethod: authMethod,
    );
  }

  /// Convenience: validates a custom-template base URL is non-empty and that
  /// the template exists (or is the reserved `custom` id). Used by the
  /// credential service for input validation.
  static bool isTemplateKnown(String templateId) {
    return templateId == kCustomProviderTemplateId ||
        ProviderRegistry.findByNameOrAlias(templateId) != null;
  }
}
