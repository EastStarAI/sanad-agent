import 'dart:convert';

import 'package:dbus/dbus.dart';

import 'agent_secret_store_contract.dart';

abstract interface class LinuxSecretServiceClient {
  Future<String?> read(Map<String, String> attributes);
  Future<void> write({
    required Map<String, String> attributes,
    required String label,
    required String value,
  });
  Future<void> delete(Map<String, String> attributes);
}

class LinuxSecretServiceAgentSecretStore implements AgentSecretStore {
  LinuxSecretServiceAgentSecretStore({
    required this.scope,
    LinuxSecretServiceClient? client,
  }) : _client = client ?? DBusLinuxSecretServiceClient();

  final String scope;
  final LinuxSecretServiceClient _client;

  Map<String, String> _attributes(String key) => {
    'application': 'sanad-agent',
    'home': scope,
    'entry': key,
  };

  @override
  Future<String?> read(String key) =>
      _guard('read', () => _client.read(_attributes(key)));

  @override
  Future<void> write(String key, String value) => _guard(
    'write',
    () => _client.write(
      attributes: _attributes(key),
      label: 'Sanad Agent credential',
      value: value,
    ),
  );

  @override
  Future<void> delete(String key) =>
      _guard('delete', () => _client.delete(_attributes(key)));

  Future<T> _guard<T>(String operation, Future<T> Function() action) async {
    try {
      return await action();
    } on AgentSecretStoreUnavailable {
      rethrow;
    } catch (_) {
      throw _failure(operation);
    }
  }

  AgentSecretStoreUnavailable _failure(String operation) =>
      AgentSecretStoreUnavailable(
        'Linux Secret Service $operation failed or is unavailable. Ensure an '
        'unlocked Secret Service session is available.',
      );
}

/// Direct implementation of the freedesktop.org Secret Service D-Bus API.
///
/// The plain session algorithm relies on the owner-only session bus transport.
/// Secret bytes never enter process arguments or environment variables.
class DBusLinuxSecretServiceClient implements LinuxSecretServiceClient {
  DBusLinuxSecretServiceClient({
    DBusClient? client,
    this.timeout = const Duration(seconds: 10),
  }) : _providedClient = client;

  static const _destination = 'org.freedesktop.secrets';
  static const _serviceInterface = 'org.freedesktop.Secret.Service';
  static const _collectionInterface = 'org.freedesktop.Secret.Collection';
  static const _itemInterface = 'org.freedesktop.Secret.Item';
  static const _sessionInterface = 'org.freedesktop.Secret.Session';
  static final _servicePath = DBusObjectPath('/org/freedesktop/secrets');
  static final _noPrompt = DBusObjectPath('/');

  final DBusClient? _providedClient;
  final Duration timeout;

  @override
  Future<String?> read(Map<String, String> attributes) =>
      _withClient((client) async {
        final paths = await _searchUnlocked(client, attributes);
        if (paths.isEmpty) return null;
        return _withSession(client, (session) async {
          final response = await _call(
            _object(client, paths.first),
            _itemInterface,
            'GetSecret',
            [session],
            DBusSignature('(oayays)'),
          );
          final secret = response.returnValues.single.asStruct();
          return utf8.decode(secret[2].asByteArray().toList());
        });
      });

  @override
  Future<void> write({
    required Map<String, String> attributes,
    required String label,
    required String value,
  }) => _withClient((client) async {
    final collection = await _defaultCollection(client);
    await _requireUnlocked(client, collection);
    await _withSession(client, (session) async {
      final response = await _call(
        _object(client, collection),
        _collectionInterface,
        'CreateItem',
        [
          DBusDict.stringVariant({
            'org.freedesktop.Secret.Item.Label': DBusString(label),
            'org.freedesktop.Secret.Item.Attributes': _stringDict(attributes),
          }),
          _secret(session, value),
          const DBusBoolean(true),
        ],
        DBusSignature('oo'),
      );
      _requireNoPrompt(response.returnValues[1].asObjectPath());
    });
  });

  @override
  Future<void> delete(Map<String, String> attributes) =>
      _withClient((client) async {
        final response = await _call(
          _service(client),
          _serviceInterface,
          'SearchItems',
          [_stringDict(attributes)],
          DBusSignature('aoao'),
        );
        final unlocked = response.returnValues[0].asObjectPathArray().toList();
        final locked = response.returnValues[1].asObjectPathArray().toList();
        if (locked.isNotEmpty) {
          throw const AgentSecretStoreUnavailable(
            'Linux Secret Service entries are locked.',
          );
        }
        for (final path in unlocked) {
          final deleted = await _call(
            _object(client, path),
            _itemInterface,
            'Delete',
            const [],
            DBusSignature('o'),
          );
          _requireNoPrompt(deleted.returnValues.single.asObjectPath());
        }
      });

  Future<List<DBusObjectPath>> _searchUnlocked(
    DBusClient client,
    Map<String, String> attributes,
  ) async {
    final response = await _call(
      _service(client),
      _serviceInterface,
      'SearchItems',
      [_stringDict(attributes)],
      DBusSignature('aoao'),
    );
    final unlocked = response.returnValues[0].asObjectPathArray().toList();
    final locked = response.returnValues[1].asObjectPathArray().toList();
    if (locked.isNotEmpty) {
      throw const AgentSecretStoreUnavailable(
        'Linux Secret Service entries are locked.',
      );
    }
    return unlocked;
  }

  Future<DBusObjectPath> _defaultCollection(DBusClient client) async {
    final response = await _call(
      _service(client),
      _serviceInterface,
      'ReadAlias',
      const [DBusString('default')],
      DBusSignature('o'),
    );
    final path = response.returnValues.single.asObjectPath();
    if (path == _noPrompt) {
      throw const AgentSecretStoreUnavailable(
        'Linux Secret Service has no default collection.',
      );
    }
    return path;
  }

  Future<void> _requireUnlocked(
    DBusClient client,
    DBusObjectPath collection,
  ) async {
    final locked = await _object(client, collection)
        .getProperty(
          _collectionInterface,
          'Locked',
          signature: DBusSignature.boolean,
        )
        .timeout(timeout);
    if (locked.asBoolean()) {
      throw const AgentSecretStoreUnavailable(
        'Linux Secret Service default collection is locked.',
      );
    }
  }

  Future<T> _withSession<T>(
    DBusClient client,
    Future<T> Function(DBusObjectPath session) action,
  ) async {
    final opened = await _call(
      _service(client),
      _serviceInterface,
      'OpenSession',
      const [DBusString('plain'), DBusVariant(DBusString(''))],
      DBusSignature('vo'),
    );
    final session = opened.returnValues[1].asObjectPath();
    try {
      return await action(session);
    } finally {
      try {
        await _call(
          _object(client, session),
          _sessionInterface,
          'Close',
          const [],
          DBusSignature.empty,
        );
      } catch (_) {
        // Cleanup must not hide the operation's authoritative result.
      }
    }
  }

  Future<T> _withClient<T>(Future<T> Function(DBusClient client) action) async {
    final client = _providedClient ?? DBusClient.session();
    try {
      return await action(client).timeout(timeout);
    } finally {
      if (_providedClient == null) await client.close();
    }
  }

  Future<DBusMethodSuccessResponse> _call(
    DBusRemoteObject object,
    String interface,
    String method,
    List<DBusValue> values,
    DBusSignature replySignature,
  ) => object
      .callMethod(
        interface,
        method,
        values,
        replySignature: replySignature,
        allowInteractiveAuthorization: false,
      )
      .timeout(timeout);

  DBusRemoteObject _service(DBusClient client) => _object(client, _servicePath);

  DBusRemoteObject _object(DBusClient client, DBusObjectPath path) =>
      DBusRemoteObject(client, name: _destination, path: path);

  DBusDict _stringDict(Map<String, String> values) => DBusDict(
    DBusSignature.string,
    DBusSignature.string,
    values.map((key, value) => MapEntry(DBusString(key), DBusString(value))),
  );

  DBusStruct _secret(DBusObjectPath session, String value) => DBusStruct([
    session,
    DBusArray.byte(const []),
    DBusArray.byte(utf8.encode(value)),
    const DBusString('text/plain; charset=utf8'),
  ]);

  void _requireNoPrompt(DBusObjectPath prompt) {
    if (prompt != _noPrompt) {
      throw const AgentSecretStoreUnavailable(
        'Linux Secret Service requires interactive authorization.',
      );
    }
  }
}
