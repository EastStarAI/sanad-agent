/// Gateway-authored, display-only identity for an authenticated command sender.
///
/// This metadata is correlation context only. It never grants permission or
/// changes command execution and must remain safe when absent or malformed.
final class AuthenticatedCommandOrigin {
  const AuthenticatedCommandOrigin({
    required this.version,
    required this.clientSessionId,
    required this.clientInstanceId,
    required this.clientKind,
    required this.platformFamily,
  });

  static const _clientKinds = {'web', 'desktop', 'mobile'};
  static const _platformFamilies = {
    'web',
    'macos',
    'windows',
    'linux',
    'ios',
    'android',
  };

  final int version;
  final String? clientSessionId;
  final String? clientInstanceId;
  final String clientKind;
  final String platformFamily;

  factory AuthenticatedCommandOrigin.fromEnvelope(
    Map<String, dynamic> envelope,
  ) {
    final raw = envelope['origin_client'];
    if (raw is! Map) return AuthenticatedCommandOrigin.unknown();
    final origin = Map<String, dynamic>.from(raw);
    final version = origin['version'];
    if (version != 1) return AuthenticatedCommandOrigin.unknown();
    return AuthenticatedCommandOrigin(
      version: 1,
      clientSessionId: _boundedReference(origin['client_session_id']),
      clientInstanceId: _boundedReference(origin['client_instance_id']),
      clientKind: _allowed(origin['client_kind'], _clientKinds),
      platformFamily: _allowed(
        origin['platform_family'],
        _platformFamilies,
      ),
    );
  }

  factory AuthenticatedCommandOrigin.unknown() => const AuthenticatedCommandOrigin(
    version: 1,
    clientSessionId: null,
    clientInstanceId: null,
    clientKind: 'unknown',
    platformFamily: 'unknown',
  );

  /// A bounded label that intentionally excludes ids and free-form metadata.
  String get safeDisplay {
    if (clientKind == 'unknown' && platformFamily == 'unknown') {
      return 'authenticated client';
    }
    final kind = clientKind == 'unknown' ? 'client' : '$clientKind client';
    return platformFamily == 'unknown'
        ? 'authenticated $kind'
        : 'authenticated $kind on $platformFamily';
  }

  static String _allowed(Object? value, Set<String> allowed) {
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return allowed.contains(normalized) ? normalized : 'unknown';
  }

  static String? _boundedReference(Object? value) {
    final normalized = value?.toString().trim() ?? '';
    if (normalized.isEmpty || normalized.length > 64) return null;
    return RegExp(r'^[A-Za-z0-9-]+$').hasMatch(normalized) ? normalized : null;
  }
}
