/// Sanitized cause of a provider's last failed model discovery or connection.
///
/// The daemon owns classification and sanitization (issue 339): the Client only
/// renders [kind], [statusCode], and [endpoint], and never expects a provider
/// response body here.
class ProviderDiscoveryErrorDto {
  /// `auth`, `http`, `network`, `invalid_response`, or `unknown`.
  final String kind;
  final int? statusCode;

  /// Short English reason sent by the daemon. Never rendered: the Client owns
  /// the localized sentence for every category, so an RTL interface stays
  /// fully translated.
  final String? message;

  /// `scheme://host[:port]/path` of the probed models endpoint.
  final String? endpoint;

  /// Whether the daemon considers this failure proof that the credential or the
  /// endpoint is wrong. Only a definitive failure may block setup or contradict
  /// a `READY` badge; a non-definitive one renders as a warning beside it.
  final bool definitive;

  const ProviderDiscoveryErrorDto({
    required this.kind,
    this.statusCode,
    this.message,
    this.endpoint,
    this.definitive = true,
  });

  bool get isAuthFailure => kind == 'auth';

  static ProviderDiscoveryErrorDto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final kind = json['kind']?.toString() ?? '';
    if (kind.isEmpty) return null;
    return ProviderDiscoveryErrorDto(
      kind: kind,
      statusCode: (json['status_code'] as num?)?.toInt(),
      message: json['message']?.toString(),
      endpoint: json['endpoint']?.toString(),
      definitive: json['definitive'] as bool? ?? _defaultDefinitive(kind, json['status_code']),
    );
  }

  /// Weight of a cause from a daemon that predates the `definitive` field.
  ///
  /// A rejected credential or a proven endpoint failure is definitive; a
  /// transport, timeout, rate-limit, or provider-outage cause is not, so an
  /// older daemon's row cannot produce an error beside a `READY` badge.
  static bool _defaultDefinitive(String kind, Object? rawStatus) {
    final status = (rawStatus as num?)?.toInt();
    switch (kind) {
      case 'invalid_credential':
      case 'forbidden':
      case 'endpoint_not_found':
        return true;
      case 'http':
        return status != null &&
            status >= 400 &&
            status < 500 &&
            status != 408 &&
            status != 429;
      default:
        return false;
    }
  }

  Map<String, dynamic> toJson() => {
    'kind': kind,
    if (statusCode != null) 'status_code': statusCode,
    if (message != null) 'message': message,
    if (endpoint != null) 'endpoint': endpoint,
    'definitive': definitive,
  };

  @override
  bool operator ==(Object other) =>
      other is ProviderDiscoveryErrorDto &&
      other.kind == kind &&
      other.statusCode == statusCode &&
      other.message == message &&
      other.endpoint == endpoint &&
      other.definitive == definitive;

  @override
  int get hashCode =>
      Object.hash(kind, statusCode, message, endpoint, definitive);
}

/// Where an instance's cached model list came from.
class ProviderModelCacheDto {
  /// `live`, `fallback`, `cache_stale`, or `failed`.
  final String? source;

  /// Whether the daemon verified the list live for the current revisions.
  final bool verified;

  const ProviderModelCacheDto({this.source, this.verified = false});

  /// A preset list that the provider never confirmed.
  bool get isUnverifiedFallback => source == 'fallback' || source == 'cache_stale';

  static ProviderModelCacheDto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final source = json['source']?.toString();
    final verified = json['verified'] as bool? ?? false;
    if (source == null && !verified) return null;
    return ProviderModelCacheDto(source: source, verified: verified);
  }

  Map<String, dynamic> toJson() => {
    if (source != null) 'source': source,
    'verified': verified,
  };
}
