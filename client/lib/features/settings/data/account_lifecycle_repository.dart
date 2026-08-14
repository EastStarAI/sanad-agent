import 'package:dio/dio.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';
import 'package:sanad_client/features/auth/infrastructure/portal_auth_client.dart';
import 'package:sanad_client/features/settings/domain/account_lifecycle.dart';
import 'package:uuid/uuid.dart';

class AccountLifecycleRepository {
  AccountLifecycleRepository({
    required AuthService authService,
    PortalAuthClient? portalClient,
    String Function()? requestIdFactory,
  }) : _authService = authService,
       _portalClient = portalClient ?? PortalAuthClient(),
       _requestIdFactory = requestIdFactory ?? const Uuid().v4;

  final AuthService _authService;
  final PortalAuthClient _portalClient;
  final String Function() _requestIdFactory;

  Future<AccountLifecycleSnapshot> fetch() async {
    final token = _authService.accessToken;
    if (token == null || token.isEmpty) {
      throw const AccountLifecycleException('Sign in to manage sessions and devices.');
    }
    try {
      final data = await _portalClient.listAccountSessions(accessToken: token);
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
    } on DioException catch (error) {
      throw AccountLifecycleException(
        error.response?.statusCode == 401
            ? 'Your session is no longer available. Sign in again.'
            : 'Sessions and devices could not be refreshed.',
      );
    } on FormatException {
      throw const AccountLifecycleException('The account response was not recognized.');
    }
  }

  Future<AccountRevokeResult> revoke(AccountPrincipal principal) async {
    final token = _authService.accessToken;
    if (token == null || token.isEmpty) {
      throw const AccountLifecycleException('Sign in to manage sessions and devices.');
    }
    final requestId = _requestIdFactory();
    try {
      final data = await _portalClient.revokeAccountPrincipal(
        accessToken: token,
        targetKind: principal.kind == AccountPrincipalKind.clientSession ? 'client_session' : 'agent_device',
        targetId: principal.id,
        requestId: requestId,
      );
      if (data['result'] != 'revoked') {
        throw const AccountLifecycleException('The revoke request was not confirmed.');
      }
      return AccountRevokeResult(
        requestId: data['request_id']?.toString() ?? requestId,
        currentSessionRevoked: data['current_session_revoked'] == true,
      );
    } on DioException catch (error) {
      final unknown =
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          (error.response?.statusCode ?? 0) >= 500;
      throw AccountLifecycleException(
        unknown
            ? 'The outcome is unknown. Refresh before trying again.'
            : 'This session or device is no longer available.',
        outcomeUnknown: unknown,
      );
    }
  }
}
