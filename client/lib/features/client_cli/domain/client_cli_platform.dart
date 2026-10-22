import 'package:sanad_client/utils/app_platform.dart';

/// Single owner of the Client CLI platform boundary.
///
/// The `sanad-client` surface is a same-machine relay: it binds a loopback
/// HTTP/WebSocket server, writes an ownership record, and resolves a native
/// Sanad Home from the process environment. Those capabilities exist only on
/// desktop, so Web and mobile are remote-only and must never register,
/// construct, or read Client CLI state during startup.
///
/// Platform detection itself stays in [AppPlatform]; this type only names the
/// feature boundary that depends on it.
abstract final class ClientCliPlatform {
  static bool get isSupported => AppPlatform.isDesktop;
}
