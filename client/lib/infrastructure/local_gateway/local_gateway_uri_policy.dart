class LocalGatewayUriViolation implements Exception {
  const LocalGatewayUriViolation(this.code);

  final String code;

  @override
  String toString() => 'LocalGatewayUriViolation($code)';
}

class LocalGatewayUriPolicy {
  const LocalGatewayUriPolicy._();

  static Uri requireHttp(Uri uri) => _require(uri, expectedScheme: 'http');

  static Uri requireWebSocket(Uri uri) =>
      _require(uri, expectedScheme: 'ws');

  static Uri _require(Uri uri, {required String expectedScheme}) {
    final host = uri.host.trim().toLowerCase();
    if (uri.scheme.toLowerCase() != expectedScheme ||
        uri.userInfo.isNotEmpty ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        !_isLiteralLoopback(host)) {
      throw const LocalGatewayUriViolation('unsafe_local_gateway_uri');
    }
    return uri;
  }

  static bool _isLiteralLoopback(String host) {
    if (host == 'localhost' || host == '::1') return true;
    if (!host.startsWith('127.')) return false;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((part) {
      final value = int.tryParse(part);
      return value != null && value >= 0 && value <= 255;
    });
  }
}
