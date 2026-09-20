class PublicServiceEndpoints {
  const PublicServiceEndpoints._();

  static const String productionBackend = 'https://api.sanad.eaststarai.com';
  static const String productionPortal = 'https://portal.sanad.eaststarai.com';
  static const String localBackend = 'http://127.0.0.1:8001';
  static const String localPortal = 'http://127.0.0.1:8083';

  static String backendFor(String environment) {
    return switch (environment.trim().toLowerCase()) {
      'local' => localBackend,
      _ => productionBackend,
    };
  }

  static String portalFor(String environment) {
    return switch (environment.trim().toLowerCase()) {
      'local' => localPortal,
      _ => productionPortal,
    };
  }
}
