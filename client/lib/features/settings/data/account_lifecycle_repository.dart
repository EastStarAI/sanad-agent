import 'dart:async';

import 'package:sanad_client/features/settings/domain/account_lifecycle.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:uuid/uuid.dart';

abstract class AccountLifecycleSocket {
  Stream<Map<String, dynamic>> get responses;
  Stream<Map<String, dynamic>> get revokeResults;
  Stream<void> get changes;
  Stream<bool> get readinessChanges;
  bool get isReady;
  void emit(String event, Map<String, dynamic> payload);
}

class SanadAccountLifecycleSocket implements AccountLifecycleSocket {
  SanadAccountLifecycleSocket(this._socket);

  final SanadSocketService _socket;

  @override
  Stream<Map<String, dynamic>> get responses => _socket.accountLifecycleResponses;

  @override
  Stream<Map<String, dynamic>> get revokeResults => _socket.accountLifecycleRevokeResults;

  @override
  Stream<void> get changes => _socket.accountLifecycleChanges;

  @override
  Stream<bool> get readinessChanges =>
      _socket.lifecycleStateStream.map((state) => state == SocketLifecycleState.ready).distinct();

  @override
  bool get isReady => _socket.isReady;

  @override
  void emit(String event, Map<String, dynamic> payload) => _socket.emit(event, payload);
}

/// Application-scoped, Socket-owned account lifecycle transport.
///
/// Requests carry no bearer token or user identity. The Cloud Gateway derives
/// both the account and current refresh family from the authenticated socket.
abstract class AccountLifecycleRepository {
  Stream<void> get changes;
  Stream<bool> get readinessChanges;
  bool get isReady;
  Future<AccountLifecycleSnapshot> fetch();
  Future<AccountRevokeResult> revoke(AccountPrincipal principal);
  Future<void> dispose();
}

class AccountLifecycleSocketRepository implements AccountLifecycleRepository {
  AccountLifecycleSocketRepository({
    required AccountLifecycleSocket socket,
    String Function()? requestIdFactory,
    Duration timeout = const Duration(seconds: 5),
  }) : _socket = socket,
       _requestIdFactory = requestIdFactory ?? const Uuid().v4,
       _timeout = timeout {
    _snapshotSubscription = _socket.responses.listen(_handleSnapshotResponse);
    _revokeSubscription = _socket.revokeResults.listen(_handleRevokeResponse);
  }

  final AccountLifecycleSocket _socket;
  final String Function() _requestIdFactory;
  final Duration _timeout;
  final Map<String, Completer<Map<String, dynamic>>> _pendingSnapshots = {};
  final Map<String, Completer<Map<String, dynamic>>> _pendingRevocations = {};
  late final StreamSubscription<Map<String, dynamic>> _snapshotSubscription;
  late final StreamSubscription<Map<String, dynamic>> _revokeSubscription;

  @override
  Stream<void> get changes => _socket.changes;

  @override
  Stream<bool> get readinessChanges => _socket.readinessChanges;

  @override
  bool get isReady => _socket.isReady;

  @override
  Future<AccountLifecycleSnapshot> fetch() async {
    final data = await _request(
      event: 'get_account_lifecycle',
      pending: _pendingSnapshots,
      payload: const {'version': 1, 'limit': 100},
    );
    final rawItems = data['items'];
    final items = rawItems is List
        ? rawItems
              .whereType<Map>()
              .map((item) => AccountPrincipal.fromJson(Map<String, dynamic>.from(item)))
              .toList(growable: false)
        : const <AccountPrincipal>[];
    return AccountLifecycleSnapshot(
      items: items,
      presenceAvailable: data['presence_available'] == true,
    );
  }

  @override
  Future<AccountRevokeResult> revoke(AccountPrincipal principal) async {
    final data = await _request(
      event: 'revoke_account_principal',
      pending: _pendingRevocations,
      payload: {
        'version': 1,
        'target_kind': principal.kind == AccountPrincipalKind.clientSession ? 'client_session' : 'agent_device',
        'target_id': principal.id,
        'mode': 'target_only',
      },
    );
    if (data['result'] != 'revoked') {
      throw const AccountLifecycleException('The revoke request was not confirmed.');
    }
    return AccountRevokeResult(
      requestId: data['request_id']?.toString() ?? '',
      currentSessionRevoked: data['current_session_revoked'] == true,
    );
  }

  Future<Map<String, dynamic>> _request({
    required String event,
    required Map<String, Completer<Map<String, dynamic>>> pending,
    required Map<String, dynamic> payload,
  }) async {
    if (!_socket.isReady) {
      throw const AccountLifecycleException('Sanad Cloud is unavailable.');
    }
    final requestId = _requestIdFactory();
    final completer = Completer<Map<String, dynamic>>();
    pending[requestId] = completer;
    _socket.emit(event, {...payload, 'request_id': requestId});
    try {
      return await completer.future.timeout(_timeout);
    } on TimeoutException {
      throw AccountLifecycleException(
        event == 'revoke_account_principal'
            ? 'The outcome is unknown. Refresh before trying again.'
            : 'Sessions and devices could not be refreshed.',
        outcomeUnknown: event == 'revoke_account_principal',
      );
    } finally {
      pending.remove(requestId);
    }
  }

  void _handleSnapshotResponse(Map<String, dynamic> data) {
    _completeResponse(_pendingSnapshots, data, mutation: false);
  }

  void _handleRevokeResponse(Map<String, dynamic> data) {
    _completeResponse(_pendingRevocations, data, mutation: true);
  }

  void _completeResponse(
    Map<String, Completer<Map<String, dynamic>>> pending,
    Map<String, dynamic> data, {
    required bool mutation,
  }) {
    if (data['version'] != 1) return;
    final requestId = data['request_id']?.toString();
    if (requestId == null) return;
    final completer = pending.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (data['status'] == 'ok') {
      completer.complete(data);
      return;
    }
    final code = data['error']?.toString();
    final unavailable = code == 'unavailable';
    completer.completeError(
      AccountLifecycleException(
        unavailable
            ? mutation
                  ? 'The outcome is unknown. Refresh before trying again.'
                  : 'Sessions and devices could not be refreshed.'
            : code == 'not_authenticated'
            ? 'Sign in to manage sessions and devices.'
            : 'This session or device is no longer available.',
        outcomeUnknown: mutation && unavailable,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _snapshotSubscription.cancel();
    await _revokeSubscription.cancel();
    const error = AccountLifecycleException('Sessions and devices are unavailable.');
    for (final completer in [..._pendingSnapshots.values, ..._pendingRevocations.values]) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pendingSnapshots.clear();
    _pendingRevocations.clear();
  }
}
