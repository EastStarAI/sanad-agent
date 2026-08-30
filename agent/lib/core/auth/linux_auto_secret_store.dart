import 'dart:convert';
import 'dart:math';

import '../sanad_home/sanad_home_bootstrap.dart';
import '../sanad_home/sanad_home_boundary.dart';
import 'agent_secret_store_contract.dart';
import 'linux_secret_service.dart';

enum LinuxAgentSecretBackend {
  secretService('linux_secret_service'),
  ownerFile('linux_owner_file');

  const LinuxAgentSecretBackend(this.wireName);

  final String wireName;

  static LinuxAgentSecretBackend parse(String value) => values.firstWhere(
    (backend) => backend.wireName == value,
    orElse: () => throw const AgentSecretStoreUnavailable(
      'The selected Linux credential backend is invalid.',
    ),
  );
}

/// Owner-protected Linux credential storage for hosts without Secret Service.
///
/// This backend provides filesystem ownership protection, not encryption. The
/// complete record is replaced atomically while an inter-process lock is held.
final class LinuxOwnerFileAgentSecretStore implements AgentSecretStore {
  LinuxOwnerFileAgentSecretStore({SanadHomeBootstrap? boundary})
    : _boundary = boundary ?? SanadHomeBootstrap.identity();

  static const dataFileName = 'agent_credentials.json';
  static const lockFileName = 'agent_credentials.lock';

  final SanadHomeBootstrap _boundary;

  @override
  Future<String?> read(String key) => _guard(
    'read',
    () => _boundary.runWithFileLock(
      lockFileName,
      () async => _readAllUnlocked()[key],
    ),
  );

  @override
  Future<void> write(String key, String value) => _guard(
    'write',
    () => _boundary.runWithFileLock(lockFileName, () async {
      final records = _readAllUnlocked()..[key] = value;
      await _writeAllUnlocked(records);
      if (_readAllUnlocked()[key] != value) {
        throw const AgentSecretStoreUnavailable(
          'Linux owner-file credential write verification failed.',
        );
      }
    }),
  );

  @override
  Future<void> delete(String key) => _guard(
    'delete',
    () => _boundary.runWithFileLock(lockFileName, () async {
      final records = _readAllUnlocked();
      if (records.remove(key) == null) return;
      if (records.isEmpty) {
        await _boundary.deleteFile(dataFileName);
      } else {
        await _writeAllUnlocked(records);
      }
      if (_readAllUnlocked().containsKey(key)) {
        throw const AgentSecretStoreUnavailable(
          'Linux owner-file credential deletion verification failed.',
        );
      }
    }),
  );

  Future<Map<String, String>> readAll() => _guard(
    'read',
    () => _boundary.runWithFileLock(
      lockFileName,
      () async => Map<String, String>.unmodifiable(_readAllUnlocked()),
    ),
  );

  Future<void> deleteAll() => _guard(
    'delete',
    () => _boundary.runWithFileLock(lockFileName, () async {
      await _boundary.deleteFile(dataFileName);
      if (_boundary.fileExists(dataFileName)) {
        throw const AgentSecretStoreUnavailable(
          'Linux owner-file credential deletion verification failed.',
        );
      }
    }),
  );

  Map<String, String> _readAllUnlocked() {
    if (!_boundary.fileExists(dataFileName)) return <String, String>{};
    final decoded = jsonDecode(
      utf8.decode(_boundary.readSecretBytes(dataFileName)),
    );
    if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
      throw const AgentSecretStoreUnavailable(
        'Linux owner-file credential data is invalid.',
      );
    }
    final entries = decoded['entries'];
    if (entries is! Map<String, dynamic> ||
        entries.values.any((value) => value is! String)) {
      throw const AgentSecretStoreUnavailable(
        'Linux owner-file credential data is invalid.',
      );
    }
    return entries.map((key, value) => MapEntry(key, value as String));
  }

  Future<void> _writeAllUnlocked(Map<String, String> records) =>
      _boundary.writeSecretBytes(
        dataFileName,
        utf8.encode(jsonEncode({'version': 1, 'entries': records})),
      );

  Future<T> _guard<T>(String operation, Future<T> Function() action) async {
    try {
      return await action();
    } on AgentSecretStoreUnavailable {
      rethrow;
    } on SanadHomeBoundaryViolation {
      throw AgentSecretStoreUnavailable(
        'Linux owner-file credential $operation was rejected by the Sanad Home boundary.',
      );
    } on SanadHomeWriteFailure {
      throw AgentSecretStoreUnavailable(
        'Linux owner-file credential $operation failed.',
      );
    } catch (_) {
      throw AgentSecretStoreUnavailable(
        'Linux owner-file credential $operation failed.',
      );
    }
  }
}

/// Capability-aware Linux store with durable backend identity.
///
/// A persisted Secret Service selection never falls back when temporarily
/// unavailable. A persisted owner-file selection gets one verified migration
/// attempt per process and retains its bytes unless every target write verifies.
final class LinuxAutoAgentSecretStore implements AgentSecretStore {
  LinuxAutoAgentSecretStore({
    required this.scope,
    LinuxSecretServiceAgentSecretStore? secretService,
    LinuxOwnerFileAgentSecretStore? ownerFile,
    SanadHomeBootstrap? boundary,
  }) : _secretService =
           secretService ?? LinuxSecretServiceAgentSecretStore(scope: scope),
       _ownerFile = ownerFile ?? LinuxOwnerFileAgentSecretStore(),
       _boundary = boundary ?? SanadHomeBootstrap.identity();

  static const metadataFileName = 'agent_credential_backend.json';
  static const selectionLockFileName = 'agent_credential_backend.lock';
  static const _probePrefix = '__sanad_capability_probe__';

  final String scope;
  final LinuxSecretServiceAgentSecretStore _secretService;
  final LinuxOwnerFileAgentSecretStore _ownerFile;
  final SanadHomeBootstrap _boundary;
  LinuxAgentSecretBackend? _backend;
  bool _migrationAttempted = false;

  Future<LinuxAgentSecretBackend> get backend => _resolveBackend();

  @override
  Future<String?> read(String key) async => (await _store()).read(key);

  @override
  Future<void> write(String key, String value) async =>
      (await _store()).write(key, value);

  @override
  Future<void> delete(String key) async => (await _store()).delete(key);

  Future<AgentSecretStore> _store() async {
    final selected = await _resolveBackend();
    return selected == LinuxAgentSecretBackend.secretService
        ? _secretService
        : _ownerFile;
  }

  Future<LinuxAgentSecretBackend> _resolveBackend() async {
    final cached = _backend;
    if (cached != null) {
      if (cached == LinuxAgentSecretBackend.ownerFile) {
        await _attemptMigrationOnce();
      }
      return _backend!;
    }

    return _boundary.runWithFileLock(selectionLockFileName, () async {
      final selected = _readBackendMetadata();
      if (selected != null) {
        _backend = selected;
      } else {
        _backend = await _probeSecretService()
            ? LinuxAgentSecretBackend.secretService
            : LinuxAgentSecretBackend.ownerFile;
        await _writeBackendMetadata(_backend!);
      }
      if (_backend == LinuxAgentSecretBackend.ownerFile) {
        await _attemptMigrationOnceUnlocked();
      }
      return _backend!;
    });
  }

  LinuxAgentSecretBackend? _readBackendMetadata() {
    if (!_boundary.fileExists(metadataFileName)) return null;
    try {
      final decoded = jsonDecode(
        utf8.decode(_boundary.readSecretBytes(metadataFileName)),
      );
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const AgentSecretStoreUnavailable(
          'The selected Linux credential backend metadata is invalid.',
        );
      }
      return LinuxAgentSecretBackend.parse(decoded['backend'] as String);
    } on AgentSecretStoreUnavailable {
      rethrow;
    } catch (_) {
      throw const AgentSecretStoreUnavailable(
        'The selected Linux credential backend metadata is invalid.',
      );
    }
  }

  Future<void> _writeBackendMetadata(LinuxAgentSecretBackend backend) =>
      _boundary.writeSecretBytes(
        metadataFileName,
        utf8.encode(jsonEncode({'version': 1, 'backend': backend.wireName})),
      );

  Future<bool> _probeSecretService() async {
    final random = Random.secure();
    final key =
        '$_probePrefix${List<int>.generate(18, (_) => random.nextInt(256)).map((value) => value.toRadixString(16).padLeft(2, '0')).join()}';
    final value = List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    try {
      await _secretService.write(key, value);
      if (await _secretService.read(key) != value) return false;
      await _secretService.delete(key);
      return await _secretService.read(key) == null;
    } catch (_) {
      try {
        await _secretService.delete(key);
      } catch (_) {}
      return false;
    }
  }

  Future<void> _attemptMigrationOnce() {
    if (_migrationAttempted) return Future<void>.value();
    return _boundary.runWithFileLock(
      selectionLockFileName,
      _attemptMigrationOnceUnlocked,
    );
  }

  Future<void> _attemptMigrationOnceUnlocked() async {
    if (_migrationAttempted || _backend != LinuxAgentSecretBackend.ownerFile) {
      return;
    }
    _migrationAttempted = true;
    if (!await _probeSecretService()) return;

    final records = await _ownerFile.readAll();
    var metadataSwitched = false;
    try {
      for (final entry in records.entries) {
        await _secretService.write(entry.key, entry.value);
        if (await _secretService.read(entry.key) != entry.value) {
          throw const AgentSecretStoreUnavailable(
            'Linux credential migration verification failed.',
          );
        }
      }
      await _writeBackendMetadata(LinuxAgentSecretBackend.secretService);
      metadataSwitched = true;
      await _ownerFile.deleteAll();
      _backend = LinuxAgentSecretBackend.secretService;
    } on AgentSecretStoreUnavailable {
      if (metadataSwitched) {
        try {
          await _writeBackendMetadata(LinuxAgentSecretBackend.ownerFile);
        } catch (_) {}
      }
      _backend = LinuxAgentSecretBackend.ownerFile;
    }
  }
}
