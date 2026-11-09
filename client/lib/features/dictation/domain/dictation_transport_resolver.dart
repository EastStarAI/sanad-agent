import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/dictation/domain/dictation_identity.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/hosted_dictation_transport.dart';
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
    DeviceCapabilitiesStore? capabilities,
    LocalGatewayCredentialProvider credentialProvider =
        const LocalGatewayCredentialProvider(),
    String? localGatewayUrl,
  }) : _connectionCoordinator = connectionCoordinator,
       _capabilities = capabilities,
       _credentialProvider = credentialProvider,
       _localGatewayUrl = localGatewayUrl;

  final DeviceConnectionCoordinator _connectionCoordinator;

  /// The Client's capability authority for a device. Hosted dictation needs the
  /// Agent's own relay advertisement, so the resolver reads it from the store
  /// instead of guessing from the connection scope.
  final DeviceCapabilitiesStore? _capabilities;
  final LocalGatewayCredentialProvider _credentialProvider;
  final String? _localGatewayUrl;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async {
    if (!DictationIdentity.isValid(sessionId)) {
      throw const DictationTransportUnavailable('invalid_session_identity');
    }
    final endpoint = _connectionCoordinator.resolve(device);

    if (endpoint.scope == ConnectionScope.cloud) {
      return _resolveHosted(device: device, sessionId: sessionId);
    }

    if (!AppPlatform.isDesktop) {
      // The local channel is a loopback socket into this machine's daemon and
      // exists only on desktop; web and mobile are hosted-only.
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

  /// Hosted selection: authenticated cloud connection, the account device id,
  /// and the Agent's relay capability. Everything else fails closed.
  ///
  /// The capability is refreshed before deciding: a cold or differently-keyed
  /// cache used to report "not available on this device" for a capable Agent.
  /// A fetch that produced no entry is retryable (`relay_unavailable`), while a
  /// real advertisement saying dictation is unsupported keeps its own reason.
  Future<DictationTransport> _resolveHosted({
    required DeviceConfig device,
    required String sessionId,
  }) async {
    final store = _capabilities;
    Capability capability = const Capability();
    var known = false;
    if (store != null) {
      try {
        capability = await store.ensureFreshForAgent(device);
        known = store.capabilitiesByAgentId.containsKey(device.id);
      } on Object {
        throw const DictationTransportUnavailable('relay_unavailable');
      }
    }
    if (!capability.supportsDictation) {
      throw DictationTransportUnavailable(
        known
            ? (capability.dictationUnavailableReason ?? 'dictation_unavailable')
            : 'relay_unavailable',
      );
    }
    if (!capability.supportsDictationRelay) {
      // New Client, old Agent: dictation stays local-only for that device rather
      // than degrading into an unscoped relay.
      throw const DictationTransportUnavailable('relay_unavailable');
    }
    final accountDeviceId = device.accountDeviceId;
    if (accountDeviceId == null || accountDeviceId.isEmpty) {
      throw const DictationTransportUnavailable('relay_unavailable');
    }
    final socket = _connectionCoordinator.cloudSocketService;
    if (!socket.hasAccessToken || !socket.isConnected) {
      throw const DictationTransportUnavailable('relay_unavailable');
    }
    return HostedDictationTransport.connect(
      socket: socket,
      deviceId: accountDeviceId,
      dictationId: sessionId,
      maxFrameBytes: capability.dictationRelayMaxFrameBytes,
      // Both bounds come from the Agent's own advertisement, never from a
      // matching constant on this side.
      maxSessionBytes: capability.dictationRelayMaxSessionBytes,
      maxSessionSeconds: capability.dictationRelayMaxSessionSeconds,
    );
  }

  static Uri _asWebSocket(Uri uri) {
    if (uri.scheme == 'ws' || uri.scheme == 'wss') return uri;
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }
}
