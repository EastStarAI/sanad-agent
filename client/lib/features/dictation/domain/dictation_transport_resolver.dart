import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_uri_policy.dart';
import 'package:sanad_client/utils/app_platform.dart';

/// The only place that decides which [DictationTransport] a session uses.
///
/// Mirrors the voice path (`VoiceStreamCubit` + `DeviceConnectionCoordinator`):
/// dictation state, UI, and protocol handling stay transport-agnostic, so no
/// other dictation code may branch on connection scope.
abstract class DictationResolver {
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  });
}

class DictationTransportResolver implements DictationResolver {
  DictationTransportResolver({
    required DeviceConnectionCoordinator connectionCoordinator,
    LocalGatewayCredentialProvider credentialProvider =
        const LocalGatewayCredentialProvider(),
    String? localGatewayUrl,
  })  : _connectionCoordinator = connectionCoordinator,
        _credentialProvider = credentialProvider,
        _localGatewayUrl = localGatewayUrl;

  final DeviceConnectionCoordinator _connectionCoordinator;
  final LocalGatewayCredentialProvider _credentialProvider;
  final String? _localGatewayUrl;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async {
    final endpoint = _connectionCoordinator.resolve(device);

    if (endpoint.scope != ConnectionScope.local) {
      // A non-local transport is added here and nowhere else.
      throw const DictationTransportUnavailable('remote_scope');
    }
    if (!AppPlatform.isDesktop) {
      throw const DictationTransportUnavailable('remote_only_platform');
    }

    final baseUrl = LocalGatewayUriPolicy.requireWebSocket(
      _asWebSocket(Uri.parse(_localGatewayUrl ?? AppConfig.localGatewayUrl)),
    );

    return LocalDictationTransport.connect(
      localGatewayUrl: baseUrl,
      sessionId: sessionId,
      deviceId: device.id,
      headers: _credentialProvider.headers,
    );
  }

  static Uri _asWebSocket(Uri uri) {
    if (uri.scheme == 'ws' || uri.scheme == 'wss') return uri;
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }
}
