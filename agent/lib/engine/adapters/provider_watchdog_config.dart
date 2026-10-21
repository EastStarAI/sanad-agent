/// Central provider transport watchdog defaults (Plan 50b).
///
/// [connectTimeout] bounds `ProviderRequestTransport.post`/`send` until the
/// response (for a non-streamed `post`, the whole body) arrives. Compaction
/// passes replace only that field with the compaction pass timeout
/// (`Config.compactionPassTimeout`, Task 118); normal turns keep these
/// defaults.
class ProviderWatchdogConfig {
  const ProviderWatchdogConfig({
    this.connectTimeout = const Duration(seconds: 90),
    this.firstByteTimeout = const Duration(seconds: 120),
    this.streamIdleTimeout = const Duration(seconds: 120),
    this.totalTimeout,
  });

  static const defaults = ProviderWatchdogConfig();

  final Duration connectTimeout;
  final Duration firstByteTimeout;
  final Duration streamIdleTimeout;
  final Duration? totalTimeout;

  ProviderWatchdogConfig copyWith({
    Duration? connectTimeout,
    Duration? firstByteTimeout,
    Duration? streamIdleTimeout,
    Duration? totalTimeout,
  }) => ProviderWatchdogConfig(
    connectTimeout: connectTimeout ?? this.connectTimeout,
    firstByteTimeout: firstByteTimeout ?? this.firstByteTimeout,
    streamIdleTimeout: streamIdleTimeout ?? this.streamIdleTimeout,
    totalTimeout: totalTimeout ?? this.totalTimeout,
  );
}
