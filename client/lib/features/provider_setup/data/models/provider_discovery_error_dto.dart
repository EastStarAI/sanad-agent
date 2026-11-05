/// Sanitized cause of a provider's last failed model discovery or connection.
///
/// The daemon owns classification and sanitization (issue 339): the Client only
/// renders [kind], [statusCode], and [endpoint], and never expects a provider
/// response body here.
class ProviderDiscoveryErrorDto {
  /// `auth`, `http`, `network`, `invalid_response`, or `unknown`.
  final String kind;
  final int? statusCode;

  /// Short English reason sent by the daemon. Used as a fallback for an
  /// unknown [kind]; localized kinds render their own text.
  final String? message;

  /// `scheme://host[:port]/path` of the probed models endpoint.
  final String? endpoint;

  /// Whether the daemon considers this failure proof that the credential or the
  /// endpoint is wrong. Only a definitive failure may block setup.
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
      definitive: json['definitive'] as bool? ?? true,
    );
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
