/// Central provider transport watchdog defaults (Plan 50b).
class ProviderWatchdogConfig {
  const ProviderWatchdogConfig({
    this.connectTimeout = const Duration(seconds: 30),
    this.firstByteTimeout = const Duration(seconds: 60),
    this.streamIdleTimeout = const Duration(seconds: 120),
    this.totalTimeout,
  });

  static const defaults = ProviderWatchdogConfig();

  final Duration connectTimeout;
  final Duration firstByteTimeout;
  final Duration streamIdleTimeout;
  final Duration? totalTimeout;
}
