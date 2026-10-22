import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../constants.dart';
import '../sanad_home/sanad_home_bootstrap.dart';
import '../sanad_home/test_runtime_isolation.dart';
import 'agent_secret_namespaces.dart';
import 'agent_secret_store.dart';

export 'secret_vault_policy.dart';

/// One owner's entries inside the Agent vault, cached for synchronous reads.
class SecretVaultNamespace {
  SecretVaultNamespace._(this.prefix, this.indexKey, this.legacyFile);

  final String prefix;
  final String indexKey;

  /// Legacy owner-only plaintext file this namespace migrates from; `null`
  /// for a namespace that never had a plaintext predecessor.
  final String? legacyFile;

  final Map<String, String> _values = {};

  /// Legacy values kept readable only while their migration has not
  /// verified; never written to.
  Map<String, String> _legacy = const {};

  String? read(String id) => _values[id] ?? _legacy[id];

  List<String> get ids =>
      {..._values.keys, ..._legacy.keys}.toList(growable: false);

  String _key(String id) => '$prefix$id';
}

/// Agent-owned secret vault: provider credentials and MCP secrets stored in
/// [AgentSecretStore] (macOS Keychain, Windows DPAPI, Linux Secret Service or
/// the Linux headless owner-only fallback).
///
/// Reads are served from an in-process cache loaded when the vault opens.
/// Every write is verified by read-back, committed to the owner index under a
/// cross-process lock, and announced through a generation marker so another
/// process (for example the daemon while `sanad setup` runs) reloads it.
///
/// Opening migrates `provider_secrets.json` and `mcp_secrets.json`: entries
/// not yet in the vault are written and verified, the index is committed, and
/// only then is the legacy file deleted. A failed migration keeps the file in
/// place and its values readable; the next open retries. A value already in
/// the vault always wins over a legacy value. An older Agent on the same Home
/// no longer finds these secrets after a successful migration.
class SecretVaults {
  SecretVaults._(this.store, this._home)
    : providers = SecretVaultNamespace._(
        AgentSecretNamespaces.providerPrefix,
        AgentSecretNamespaces.providerIndexKey,
        'provider_secrets.json',
      ),
      mcp = SecretVaultNamespace._(
        AgentSecretNamespaces.mcpPrefix,
        AgentSecretNamespaces.mcpIndexKey,
        'mcp_secrets.json',
      ),
      custom = SecretVaultNamespace._(
        AgentSecretNamespaces.customPrefix,
        AgentSecretNamespaces.customIndexKey,
        null,
      );

  static final _logger = Logger('SecretVaults');
  static final Map<String, SecretVaults> _opened = {};

  static const _lockFile = 'secret_vault.lock';
  static const _generationFile = 'secret_vault.generation';
  static const _eventsFile = 'secret_vault_events.jsonl';

  /// Replays vault lifecycle events (migration results, an unavailable
  /// vault) into the agent log and clears them.
  ///
  /// The vault can open in a process without an agent log listener (the CLI,
  /// or the daemon before logging starts), so these events are kept in an
  /// owner-only Sanad Home file instead of being lost. They carry counts and
  /// namespaces only, never secret values. Call after logging is initialized.
  static void drainStartupEvents() {
    final home = SanadHomeBootstrap.identity();
    if (!home.fileExists(_eventsFile)) return;
    try {
      final lines = const LineSplitter().convert(
        utf8.decode(home.readSecretBytes(_eventsFile)),
      );
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final event = jsonDecode(line) as Map<String, dynamic>;
        final level = event['level'] == 'warning' ? Level.WARNING : Level.INFO;
        _logger.log(level, '${event['message']} (recorded ${event['at']})');
      }
    } catch (_) {
      _logger.warning('Secret vault event log was unreadable and was cleared.');
    }
    home.deleteFileSync(_eventsFile);
  }

  void _event(Level level, String message) {
    final line = jsonEncode({
      'at': DateTime.now().toUtc().toIso8601String(),
      'level': level == Level.WARNING ? 'warning' : 'info',
      'message': message,
    });
    try {
      final existing = _home.fileExists(_eventsFile)
          ? utf8.decode(_home.readSecretBytes(_eventsFile))
          : '';
      _home.writeSecretBytesSync(_eventsFile, utf8.encode('$existing$line\n'));
    } catch (_) {
      // The event is still logged below when a listener exists.
      _logger.log(level, message);
    }
  }

  final AgentSecretStore store;
  final SanadHomeBootstrap _home;
  final SecretVaultNamespace providers;
  final SecretVaultNamespace mcp;

  /// User secrets acquired through `system_request_secret` (Plan 84). Created
  /// in the vault only; there is no plaintext file to migrate from.
  final SecretVaultNamespace custom;

  bool _available = true;
  String? _unavailableReason;
  String? _unavailableMessage;
  String? _seenGeneration;
  Timer? _watch;

  /// Whether the platform vault answered when this instance opened.
  bool get available => _available;

  /// Non-secret reason code when [available] is false, one of
  /// [AgentSecretStoreUnavailableReason].
  String? get unavailableReason => _unavailableReason;

  /// The diagnostic that explained the closed vault; it never carries a value.
  String? get unavailableMessage => _unavailableMessage;

  /// The non-secret label the local gateway `/health` payload reports.
  String get statusLabel => _available ? 'available' : 'unavailable';

  List<SecretVaultNamespace> get _namespaces => [providers, mcp, custom];

  /// The vault opened by this process for the Home at [homePath], if any.
  static SecretVaults? forHome(String homePath) =>
      _opened[_canonical(homePath)];

  /// The vault opened for the active Sanad Home, if any.
  static SecretVaults? get current => forHome(getSanadHome());

  /// Opens (once per process) the vault for the active Home, migrating
  /// legacy files. Never throws: an unavailable vault keeps legacy values
  /// readable and rejects writes.
  static Future<SecretVaults> open({AgentSecretStore? store}) async {
    _rejectUnisolatedTestOpen();
    final key = _canonical(getSanadHome());
    final existing = _opened[key];
    if (existing != null) return existing;
    final vaults = await openDetached(store: store);
    _opened[key] = vaults;
    return vaults;
  }

  /// Opens an instance that is not registered for this process (another
  /// process's view in tests).
  static Future<SecretVaults> openDetached({AgentSecretStore? store}) async {
    _rejectUnisolatedTestOpen();
    final home = SanadHomeBootstrap.identity();
    AgentSecretStore? backend = store;
    AgentSecretStoreUnavailable? creationFailure;
    if (backend == null) {
      try {
        backend = createAgentSecretStore();
      } on AgentSecretStoreUnavailable catch (error) {
        creationFailure = error;
        backend = null;
      }
    }
    final vaults = SecretVaults._(
      backend ?? const _UnavailableSecretStore(),
      home,
    );
    vaults._available = backend != null;
    if (creationFailure != null) {
      vaults._unavailableReason = creationFailure.reasonCode;
      vaults._unavailableMessage = creationFailure.message;
    }
    await vaults._initialize();
    return vaults;
  }

  /// Opening migrates and deletes legacy secret files, so a Dart test may
  /// open a vault only for an explicitly isolated, non-default Home.
  static void _rejectUnisolatedTestOpen() => rejectUnisolatedTestHomeAccess(
    'open the Agent secret vault',
    path: getSanadHome(),
  );

  /// Closes every vault this process opened.
  static Future<void> closeAll() async {
    for (final vaults in _opened.values) {
      vaults.stopWatching();
    }
    _opened.clear();
  }

  static String _canonical(String path) {
    try {
      final dir = Directory(path);
      if (dir.existsSync()) return dir.resolveSymbolicLinksSync();
    } on FileSystemException {
      // Lexical form below.
    }
    return p.normalize(path);
  }

  Future<void> _initialize() async {
    try {
      await _withLock(() async {
        for (final namespace in _namespaces) {
          await _migrate(namespace);
        }
      });
      await _reload();
    } on AgentSecretStoreUnavailable catch (error) {
      _available = false;
      _unavailableReason = error.reasonCode;
      _unavailableMessage = error.message;
      _event(
        Level.WARNING,
        'Agent vault unavailable (${error.reasonCode}): ${error.message}',
      );
      for (final namespace in _namespaces) {
        namespace._legacy = _readLegacy(namespace) ?? const {};
      }
    }
    _seenGeneration = _readGeneration();
  }

  /// Polls the generation marker so writes from another process become
  /// visible without a restart.
  void startWatching({Duration interval = const Duration(seconds: 2)}) {
    _watch ??= Timer.periodic(interval, (_) {
      unawaited(refreshIfStale().catchError((_) {}));
    });
  }

  void stopWatching() {
    _watch?.cancel();
    _watch = null;
  }

  /// Reloads the cache when another process committed a change.
  Future<void> refreshIfStale() async {
    final generation = _readGeneration();
    if (generation == _seenGeneration) return;
    await _reload();
    _seenGeneration = generation;
  }

  /// Writes [entries] into [namespace], verifies each by read-back, and
  /// commits them to the owner index.
  Future<void> put(
    SecretVaultNamespace namespace,
    Map<String, String> entries,
  ) async {
    if (entries.isEmpty) return;
    _requireAvailable();
    await _withLock(() async {
      await _writeVerified(namespace, entries);
      final index = await _readIndex(namespace);
      await _writeIndex(namespace, {...index, ...entries.keys});
      namespace._values.addAll(entries);
      _bumpGeneration();
    });
  }

  /// Removes [ids] from [namespace]: the index first, then the entries, so a
  /// crash leaves at most an unreachable entry.
  Future<void> remove(
    SecretVaultNamespace namespace,
    Iterable<String> ids,
  ) async {
    final targets = ids.toSet();
    if (targets.isEmpty) return;
    _requireAvailable();
    await _withLock(() async {
      final index = await _readIndex(namespace);
      await _writeIndex(namespace, index.difference(targets));
      for (final id in targets) {
        await store.delete(namespace._key(id));
        namespace._values.remove(id);
      }
      _bumpGeneration();
    });
  }

  void _requireAvailable() {
    if (!_available) {
      throw AgentSecretStoreUnavailable(
        'The Agent credential vault is unavailable'
        '${_unavailableReason == null ? '' : ' ($_unavailableReason)'}; '
        'the secret was not saved.',
        reasonCode:
            _unavailableReason ?? AgentSecretStoreUnavailableReason.unavailable,
      );
    }
  }

  Future<void> _reload() async {
    for (final namespace in _namespaces) {
      final values = <String, String>{};
      for (final id in await _readIndex(namespace)) {
        final value = await store.read(namespace._key(id));
        if (value != null) values[id] = value;
      }
      namespace._values
        ..clear()
        ..addAll(values);
      if (namespace._legacy.isNotEmpty) {
        namespace._legacy = _readLegacy(namespace) ?? const {};
      }
    }
  }

  Future<Set<String>> _readIndex(SecretVaultNamespace namespace) async {
    final raw = await store.read(namespace.indexKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return {for (final id in decoded) id.toString()};
    } on FormatException {
      _logger.warning('Ignoring an unreadable ${namespace.prefix} index.');
    }
    return <String>{};
  }

  Future<void> _writeIndex(
    SecretVaultNamespace namespace,
    Set<String> ids,
  ) async {
    final encoded = jsonEncode(ids.toList()..sort());
    await store.write(namespace.indexKey, encoded);
    if (await store.read(namespace.indexKey) != encoded) {
      throw StateError('Secret vault index verification failed.');
    }
  }

  Future<void> _writeVerified(
    SecretVaultNamespace namespace,
    Map<String, String> entries,
  ) async {
    for (final entry in entries.entries) {
      final key = namespace._key(entry.key);
      await store.write(key, entry.value);
      if (await store.read(key) != entry.value) {
        throw StateError('Secret vault verification failed.');
      }
    }
  }

  /// Migrates one legacy file. Returns without deleting it when anything
  /// fails; vault values already present are never overwritten.
  Future<void> _migrate(SecretVaultNamespace namespace) async {
    final legacyFile = namespace.legacyFile;
    if (legacyFile == null) return;
    final legacy = _readLegacy(namespace);
    if (legacy == null) {
      if (_home.fileExists(legacyFile)) {
        // Unreadable legacy file: keep it for manual recovery.
        namespace._legacy = const {};
      }
      return;
    }
    try {
      final index = await _readIndex(namespace);
      final pending = {
        for (final entry in legacy.entries)
          if (!index.contains(entry.key)) entry.key: entry.value,
      };
      await _writeVerified(namespace, pending);
      await _writeIndex(namespace, {...index, ...pending.keys});
      _home.deleteFileSync(legacyFile);
      final sidecar = '$legacyFile.lock';
      if (_home.fileExists(sidecar)) _home.deleteFileSync(sidecar);
      namespace._legacy = const {};
      _bumpGeneration();
      _event(
        Level.INFO,
        'Migrated ${pending.length} ${namespace.prefix} secret(s) into the '
        'Agent vault and deleted $legacyFile.',
      );
    } on AgentSecretStoreUnavailable {
      rethrow;
    } catch (error) {
      namespace._legacy = legacy;
      _event(
        Level.WARNING,
        'Secret migration for ${namespace.prefix} did not verify '
        '(${error.runtimeType}); $legacyFile stays in place.',
      );
    }
  }

  /// Parses a legacy plaintext file into `id -> stored value`; `null` when the
  /// file is absent or unreadable. Values are never logged.
  Map<String, String>? _readLegacy(SecretVaultNamespace namespace) {
    final legacyFile = namespace.legacyFile;
    if (legacyFile == null || !_home.fileExists(legacyFile)) return null;
    try {
      final bytes = _home.readSecretBytes(legacyFile);
      if (bytes.isEmpty) return const {};
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      if (namespace == providers) {
        final instances = decoded['instances'];
        if (instances is! Map) return const {};
        return {
          for (final entry in instances.entries)
            if (entry.value is Map)
              entry.key.toString(): jsonEncode(entry.value),
        };
      }
      return {
        for (final entry in decoded.entries)
          entry.key.toString(): entry.value.toString(),
      };
    } catch (_) {
      _event(Level.WARNING, 'Legacy $legacyFile is unreadable; kept.');
      return null;
    }
  }

  Future<T> _withLock<T>(Future<T> Function() action) async {
    if (!_home.fileExists(_lockFile)) {
      _home.writeSecretBytesSync(_lockFile, const []);
    }
    final handle = File(
      p.join(_home.canonicalRoot(), _lockFile),
    ).openSync(mode: FileMode.append);
    try {
      await handle.lock(FileLock.blockingExclusive);
      return await action();
    } finally {
      try {
        handle.unlockSync();
      } catch (_) {}
      handle.closeSync();
    }
  }

  String? _readGeneration() {
    if (!_home.fileExists(_generationFile)) return null;
    try {
      return utf8.decode(_home.readSecretBytes(_generationFile));
    } catch (_) {
      return null;
    }
  }

  void _bumpGeneration() {
    final generation = const Uuid().v4();
    _home.writeSecretBytesSync(_generationFile, utf8.encode(generation));
    _seenGeneration = generation;
  }
}

class _UnavailableSecretStore implements AgentSecretStore {
  const _UnavailableSecretStore();

  static const _error = AgentSecretStoreUnavailable(
    'This operating system has no supported Sanad credential vault.',
    reasonCode: AgentSecretStoreUnavailableReason.noStore,
  );

  @override
  Future<String?> read(String key) async => throw _error;

  @override
  Future<void> write(String key, String value) async => throw _error;

  @override
  Future<void> delete(String key) async => throw _error;
}
