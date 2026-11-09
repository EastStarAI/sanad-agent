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

/// How long a startup path waits for the operating-system credential store to
/// answer before it treats the vault as not ready.
///
/// A daemon opens its vault without waiting, so the first consumer that needs a
/// secret gives the store this bounded window and then reports `vault_not_ready`
/// instead of blocking a listener or a turn behind a locked keyring or a dialog
/// nobody answered.
const secretVaultStartupReadyDeadline = Duration(seconds: 5);

/// How far an open of the Agent vault has got.
///
/// A daemon opens its vault without waiting for the operating-system store, so
/// "the vault is not available" and "the vault has not answered yet" are
/// different answers. `/health` reports this state and the credential resolver
/// refuses to call an unread value absent.
enum SecretVaultStatus {
  /// The open started and the operating-system store has not answered yet.
  opening,

  /// The store answered; cached values are the vault's real contents.
  available,

  /// The store refused or failed; the vault stays closed.
  unavailable,
}

/// The readiness of the Agent vault as another owner observes it.
///
/// A caller that can wait (a resolver, a health probe, an admin route) takes
/// this narrow view instead of the vault itself, so it never reaches into a
/// vault's cache and never blocks on an operating-system call.
abstract interface class SecretVaultReadiness {
  /// Whether the open has settled, successfully or not.
  bool get isReady;

  /// Completes when the open settles, or at [deadline]; never throws.
  ///
  /// Returns whether the vault is ready.
  Future<bool> readyWithin(Duration deadline);
}

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
class SecretVaults implements SecretVaultReadiness {
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

  /// Replays recorded vault lifecycle history into the agent log and clears it.
  ///
  /// The vault can open in a process without an agent log listener (the CLI, or
  /// the daemon before logging starts), so outcomes that will not be observed
  /// again are kept in an owner-only Sanad Home file: a completed migration, a
  /// migration whose verification failed, and an unreadable legacy file. A
  /// closed vault is deliberately not recorded, because every start observes
  /// that condition itself and reports it as one current-state line.
  ///
  /// Recorded attempts are history, never current state: they are logged at
  /// INFO, deduplicated, and carry the timestamp of the earliest occurrence.
  /// They carry counts and namespaces only, never secret values. Call after
  /// logging is initialized.
  static void drainStartupEvents() {
    final home = SanadHomeBootstrap.identity();
    if (!home.fileExists(_eventsFile)) return;
    try {
      final lines = const LineSplitter().convert(
        utf8.decode(home.readSecretBytes(_eventsFile)),
      );
      final history = <String, ({String at, int count})>{};
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final event = jsonDecode(line) as Map<String, dynamic>;
        final message = event['message']?.toString();
        if (message == null || message.isEmpty) continue;
        final at = event['at']?.toString() ?? '';
        final seen = history[message];
        history[message] = seen == null
            ? (at: at, count: 1)
            : (at: seen.at, count: seen.count + 1);
      }
      for (final entry in history.entries) {
        final repeats = entry.value.count > 1
            ? ', repeated ${entry.value.count} times'
            : '';
        _logger.info(
          'Recorded vault history: ${entry.key} '
          '(recorded ${entry.value.at}$repeats)',
        );
      }
    } catch (_) {
      _logger.info('Secret vault event log was unreadable and was cleared.');
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
      // The event is still logged below when a listener exists; it is history,
      // so it never competes with the one current-state line.
      _logger.info(message);
    }
  }

  final AgentSecretStore store;
  final SanadHomeBootstrap _home;
  final SecretVaultNamespace providers;
  final SecretVaultNamespace mcp;

  /// User secrets acquired through `system_request_secret` (Plan 84). Created
  /// in the vault only; there is no plaintext file to migrate from.
  final SecretVaultNamespace custom;

  String? _unavailableReason;
  String? _unavailableMessage;
  String? _seenGeneration;
  Timer? _watch;
  final Completer<void> _ready = Completer<void>();
  bool _stateReported = false;

  /// Whether the platform vault answered when this instance opened.
  bool get available => _status == SecretVaultStatus.available;

  /// How far this instance's open has got.
  SecretVaultStatus get status => _status;

  /// Whether the open settled, successfully or not.
  @override
  bool get isReady => _ready.isCompleted;

  /// Completes when this instance's open settles; never completes on a store
  /// that never answers.
  Future<void> get ready => _ready.future;

  /// Waits for the open to settle, but never longer than [deadline].
  ///
  /// Returns whether the vault is ready. It never throws, so a caller on a
  /// startup or turn path cannot be turned into an unbounded wait by an
  /// operating-system store that never answers.
  @override
  Future<bool> readyWithin(Duration deadline) async {
    if (isReady) return true;
    try {
      await _ready.future.timeout(deadline);
    } on TimeoutException {
      return false;
    }
    return true;
  }

  SecretVaultStatus _status = SecretVaultStatus.available;

  /// Logs this process's one Agent vault state line.
  ///
  /// Exactly one line per process describes the current state: a WARNING naming
  /// what is unreadable and how to recover when the vault is closed, and an INFO
  /// line when it is available or still opening. Repeated calls log nothing, so
  /// a start can never print the same condition twice.
  void logStartupState() {
    if (_stateReported) return;
    _stateReported = true;
    switch (_status) {
      case SecretVaultStatus.available:
        _logger.info('Agent vault available.');
      case SecretVaultStatus.opening:
        _logger.info(
          'Agent vault is still opening; provider keys, MCP secrets, user '
          'secrets and the Device Credential become readable when the '
          'operating-system credential store answers.',
        );
      case SecretVaultStatus.unavailable:
        _logger.warning(unavailableStateMessage);
    }
  }

  /// The one actionable line a closed vault produces.
  ///
  /// It states what is unreadable, why, and how to recover without leaving the
  /// terminal, so an operator who upgraded the Agent never has to discover a
  /// silent loss of provider keys and the Device Credential from a single line.
  /// It never carries a secret value.
  String get unavailableStateMessage {
    final reason =
        _unavailableReason ?? AgentSecretStoreUnavailableReason.unavailable;
    final diagnostic = _unavailableMessage;
    final recovery = Platform.isMacOS
        ? 'Recovery: run `sanad vault authorize` in a terminal and approve the '
              'one-time macOS Keychain authorization for '
              '$agentVaultKeychainService; if no dialog appears, open Keychain '
              'Access, select those items under the login keychain, and add the '
              'Agent binary to Access Control.'
        : 'Recovery: run `sanad vault authorize` in a session where the '
              'operating-system credential store is unlocked (Windows DPAPI or '
              'the Linux Secret Service).';
    return [
      'The Agent vault is closed ($reason); provider keys, MCP secrets, user '
          'secrets and the Device Credential cannot be read.',
      if (diagnostic != null && diagnostic.isNotEmpty) diagnostic,
      recovery,
      'No secret is deleted while the vault is closed.',
    ].join(' ');
  }

  /// Non-secret reason code when [available] is false, one of
  /// [AgentSecretStoreUnavailableReason].
  String? get unavailableReason => _unavailableReason;

  /// The diagnostic that explained the closed vault; it never carries a value.
  String? get unavailableMessage => _unavailableMessage;

  /// The non-secret label the local gateway `/health` payload reports.
  String get statusLabel => switch (_status) {
    SecretVaultStatus.opening => 'opening',
    SecretVaultStatus.available => 'available',
    SecretVaultStatus.unavailable => 'unavailable',
  };

  List<SecretVaultNamespace> get _namespaces => [providers, mcp, custom];

  /// The vault opened by this process for the Home at [homePath], if any.
  static SecretVaults? forHome(String homePath) =>
      _opened[_canonical(homePath)];

  /// The vault opened for the active Sanad Home, if any.
  static SecretVaults? get current => forHome(getSanadHome());

  /// Opens (once per process) the vault for the active Home, migrating
  /// legacy files, and waits for it. Never throws: an unavailable vault keeps
  /// legacy values readable and rejects writes.
  ///
  /// Opening clears `SecretVaultPolicy.vaultSkipped`, because a process with an
  /// open vault does have credential access even when its entry point deferred
  /// the open — `run` is the command that does so.
  static Future<SecretVaults> open({AgentSecretStore? store}) async {
    final vaults = beginOpen(store: store);
    await vaults.ready;
    return vaults;
  }

  /// Starts opening the vault for the active Home and returns it immediately.
  ///
  /// A daemon uses this so its listener, banner and `/health` come up while the
  /// operating-system store is still answering — or never answers at all. The
  /// instance reports [SecretVaultStatus.opening] until [ready] completes, and a
  /// secret read or write in that window fails with
  /// [AgentSecretStoreUnavailableReason.vaultNotReady] instead of reporting a
  /// value as absent. A process that already opened the vault gets that
  /// instance back unchanged.
  static SecretVaults beginOpen({AgentSecretStore? store}) {
    _rejectUnisolatedTestOpen();
    SecretVaultPolicy.markVaultOpened();
    final key = _canonical(getSanadHome());
    final existing = _opened[key];
    if (existing != null) return existing;
    final backend = _createBackend(store);
    final vaults = SecretVaults._(
      backend.store ?? const _UnavailableSecretStore(),
      SanadHomeBootstrap.identity(),
    );
    if (backend.store == null) {
      vaults._status = SecretVaultStatus.unavailable;
      vaults._unavailableReason = backend.failure?.reasonCode;
      vaults._unavailableMessage = backend.failure?.message;
      vaults._ready.complete();
    } else {
      vaults._status = SecretVaultStatus.opening;
      unawaited(vaults._start());
    }
    _opened[key] = vaults;
    return vaults;
  }

  /// Creates this process's backend, or the failure that replaced it.
  static ({AgentSecretStore? store, AgentSecretStoreUnavailable? failure})
  _createBackend(AgentSecretStore? provided) {
    if (provided != null) return (store: provided, failure: null);
    try {
      return (store: createAgentSecretStore(), failure: null);
    } on AgentSecretStoreUnavailable catch (error) {
      return (store: null, failure: error);
    }
  }

  /// Runs the open without ever leaving an unhandled asynchronous error.
  Future<void> _start() async {
    try {
      await _initialize();
    } on AgentSecretStoreUnavailable catch (error) {
      _close(error.reasonCode, error.message);
    } catch (error) {
      _close(
        AgentSecretStoreUnavailableReason.backendError,
        'The Agent vault could not be opened (${error.runtimeType}).',
      );
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  /// Opens an instance that is not registered for this process (another
  /// process's view in tests), and waits for it. Also clears
  /// `SecretVaultPolicy.vaultSkipped`, for the same reason as [open].
  static Future<SecretVaults> openDetached({AgentSecretStore? store}) async {
    _rejectUnisolatedTestOpen();
    SecretVaultPolicy.markVaultOpened();
    final backend = _createBackend(store);
    final vaults = SecretVaults._(
      backend.store ?? const _UnavailableSecretStore(),
      SanadHomeBootstrap.identity(),
    );
    vaults._status = backend.store == null
        ? SecretVaultStatus.unavailable
        : SecretVaultStatus.available;
    vaults._unavailableReason = backend.failure?.reasonCode;
    vaults._unavailableMessage = backend.failure?.message;
    await vaults._initialize();
    if (!vaults._ready.isCompleted) vaults._ready.complete();
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
      _status = SecretVaultStatus.available;
    } on AgentSecretStoreUnavailable catch (error) {
      // A closed vault is current state, not history: every start observes it
      // itself and reports it through one state line, so it is not recorded in
      // the replay file.
      _close(error.reasonCode, error.message);
    }
    _seenGeneration = _readGeneration();
  }

  /// Marks the vault closed and keeps whatever legacy values stay readable.
  ///
  /// It never throws: it also runs from the deferred open, where an unhandled
  /// error would surface as an asynchronous failure in a process that is already
  /// serving.
  void _close(String reasonCode, String message) {
    _status = SecretVaultStatus.unavailable;
    _unavailableReason = reasonCode;
    _unavailableMessage = message;
    for (final namespace in _namespaces) {
      try {
        namespace._legacy = _readLegacy(namespace) ?? const {};
      } on Object {
        namespace._legacy = const {};
      }
    }
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
    // An opening vault has no committed generation yet; the open itself loads
    // the cache, so a poll during that window must not race it.
    if (!isReady) return;
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
    if (_status == SecretVaultStatus.available) return;
    if (_status == SecretVaultStatus.opening) {
      throw const AgentSecretStoreUnavailable(
        'The Agent vault is still opening, so the operating-system credential '
        'store has not answered yet and this secret was not saved.',
        reasonCode: AgentSecretStoreUnavailableReason.vaultNotReady,
      );
    }
    throw AgentSecretStoreUnavailable(
      'The Agent credential vault is unavailable'
      '${_unavailableReason == null ? '' : ' ($_unavailableReason)'}; '
      'the secret was not saved.',
      reasonCode:
          _unavailableReason ?? AgentSecretStoreUnavailableReason.unavailable,
    );
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
