import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cloud_endpoints.dart';
import 'runtime_context.dart';
import 'secure_runtime_file.dart';

/// Explicit override for the Web Client origin.
///
/// A chosen origin is stable per Home and Client slot, so a deployment whose
/// Portal registers a different origin keeps working by setting this.
const String sanadDevWebPortEnvironmentKey = 'SANAD_DEV_WEB_PORT';

/// Ports every hosted Portal already accepts from a browser on this machine.
///
/// Each `sanad-portal` deployment builds its credentialed CORS allowlist as the
/// built-in loopback defaults unioned with its own hosted origins, so these
/// `localhost` origins answer the auth preflight on Production, Staging, and
/// Development alike. Serving a Web Client anywhere else makes the browser block
/// its first auth request, which is the opaque failure this constant removes.
const List<int> sanadDevHostedPortalWebPorts = <int>[8080, 8082, 5173, 5174, 8083];

/// First port of the reserved range used when the Portal itself is loopback.
///
/// A local deployment registers whatever origin its operator pinned, so it can
/// accept a wide range instead of the hosted Portal's fixed loopback ports.
const int sanadDevWebPortRangeStart = 52000;

/// Number of ports reserved for a loopback Portal.
///
/// It must stay disjoint from the Agent (`58085-58185`) and VM-service
/// (`51000-51999`) ranges so one runtime can never derive another's port.
const int sanadDevWebPortRangeSize = 1000;

/// Last port of the loopback-Portal range.
const int sanadDevWebPortRangeEnd =
    sanadDevWebPortRangeStart + sanadDevWebPortRangeSize - 1;

/// Host the Web Client is always served from.
///
/// flutter_tools defaults `--web-hostname` to `any`, which binds every interface
/// and only *reports* `localhost`. Naming the loopback host keeps the browser
/// origin exactly `http://localhost:<port>` and the dev server off the network.
const String sanadDevWebHostname = 'localhost';

/// flutter_tools option that pins the Web dev server port.
const String sanadDevWebPortArgument = '--web-port=';

/// flutter_tools option that pins the Web dev server host.
const String sanadDevWebHostnameArgument = '--web-hostname=';

/// Home-relative record of the origin each Client slot was last served from.
const String sanadDevWebOriginRecordName = 'web-origin.json';

/// Devices whose browser origin decides where the Web session is stored.
///
/// `web-server` is the manual-browser device: the origin matters exactly the
/// same way, but flutter_tools opens no browser and no Chrome profile applies.
bool isSanadDevWebDevice(String device) =>
    device == 'chrome' || device == 'web-server';

/// Browser origin served by the Web dev server on [port].
String sanadDevWebOriginForPort(int port) =>
    'http://$sanadDevWebHostname:$port';

/// Deterministic first choice for one Home, Client slot, and environment.
///
/// The same inputs always resolve to the same port, which is what lets a
/// restarted Web Client resume the session stored under its origin. `environment`
/// separates local, development, staging, and production origins so one Home
/// never reuses another environment's browser storage.
int deriveSanadDevWebPort({
  required String sanadHome,
  required String clientEnvironment,
  String? clientInstanceSlot,
}) {
  final home = sanadHome.trim();
  if (home.isEmpty) {
    throw const FormatException(
      'A deterministic Web origin requires a Sanad Home directory.',
    );
  }
  final environment = clientEnvironment.trim();
  if (environment.isEmpty) {
    throw const FormatException(
      'A deterministic Web origin requires the client environment.',
    );
  }
  final slot = clientInstanceSlot?.trim() ?? '';
  final identity = 'web:$environment:${slot.isEmpty ? 'primary' : slot}:$home';
  return sanadDevWebPortRangeStart +
      stableHash(identity) % sanadDevWebPortRangeSize;
}

/// Who decides which browser origins may authenticate for this environment.
enum SanadDevWebOriginAuthority {
  /// The Portal is served on loopback by a deployment the developer owns, so its
  /// registered Web origin can be aligned with any port the launcher chooses.
  deploymentOwned,

  /// The Portal is hosted: only its own CORS loopback defaults are reachable
  /// from a browser on this machine, so the launcher must serve one of them.
  hostedPortal,
}

/// Loopback Portal URLs are owned by a local deployment; anything else is the
/// hosted Portal whose browser-reachable origins are its loopback defaults.
///
/// An empty URL means no Portal is configured at all (a local-only launch), so
/// there is no hosted allowlist to satisfy.
SanadDevWebOriginAuthority sanadDevWebOriginAuthorityFor(String portalUrl) {
  final host = Uri.tryParse(portalUrl.trim())?.host.toLowerCase() ?? '';
  if (host.isEmpty) return SanadDevWebOriginAuthority.deploymentOwned;
  const loopbackHosts = {'127.0.0.1', 'localhost', '::1'};
  return loopbackHosts.contains(host)
      ? SanadDevWebOriginAuthority.deploymentOwned
      : SanadDevWebOriginAuthority.hostedPortal;
}

/// Ports a browser served from this machine may use for this Portal, in the
/// order the launcher tries them.
///
/// A hosted Portal can only answer for its own loopback defaults, so the first
/// candidate is `8080` for a primary Client and a stable hash rotation of the
/// remaining allowlisted ports for a secondary one. A loopback Portal — or no
/// Portal at all — is deployment-owned and has exactly one derived candidate.
List<int> sanadDevWebPortCandidates({
  required String sanadHome,
  required String clientEnvironment,
  required String portalUrl,
  String? clientInstanceSlot,
}) {
  if (sanadDevWebOriginAuthorityFor(portalUrl) ==
      SanadDevWebOriginAuthority.deploymentOwned) {
    return [
      deriveSanadDevWebPort(
        sanadHome: sanadHome,
        clientEnvironment: clientEnvironment,
        clientInstanceSlot: clientInstanceSlot,
      ),
    ];
  }
  final slot = clientInstanceSlot?.trim() ?? '';
  if (slot.isEmpty) return List<int>.of(sanadDevHostedPortalWebPorts);
  // A named slot starts from the ports that are not the primary Client's, so a
  // second Web Client never defaults to the first one's origin.
  final secondary = sanadDevHostedPortalWebPorts.sublist(1);
  final offset =
      stableHash('web:$clientEnvironment:$slot:${sanadHome.trim()}') %
      secondary.length;
  return [
    for (var index = 0; index < secondary.length; index++)
      secondary[(offset + index) % secondary.length],
    sanadDevHostedPortalWebPorts.first,
  ];
}

/// Whether nothing else on this machine already owns [port] on loopback.
Future<bool> sanadDevWebPortIsFree(int port) async {
  try {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// Port a Web Client must be served from.
///
/// Precedence: the explicit `SANAD_DEV_WEB_PORT` override, the port this Home
/// and slot were last served from, then this slot's deterministic origin. A busy
/// origin is an error that names the override rather than a silent move to
/// another one: a different port is a different browser origin, and the Portal
/// only accepts the origins it was configured with.
Future<int> chooseSanadDevWebPort({
  required String sanadHome,
  required String clientEnvironment,
  required String portalUrl,
  required Map<String, String> processEnvironment,
  String? clientInstanceSlot,
  Future<bool> Function(int port)? portIsFree,
}) async {
  final rawOverride =
      processEnvironment[sanadDevWebPortEnvironmentKey]?.trim() ?? '';
  final isFree = portIsFree ?? sanadDevWebPortIsFree;
  if (rawOverride.isNotEmpty) {
    final port = int.tryParse(rawOverride);
    if (port == null || port < 1 || port > 65535) {
      throw FormatException(
        '$sanadDevWebPortEnvironmentKey must be a valid TCP port: $rawOverride',
      );
    }
    return port;
  }
  final candidates = sanadDevWebPortCandidates(
    sanadHome: sanadHome,
    clientEnvironment: clientEnvironment,
    portalUrl: portalUrl,
    clientInstanceSlot: clientInstanceSlot,
  );
  final recorded = await readSanadDevWebOriginRecord(
    sanadHome: sanadHome,
    clientInstanceSlot: clientInstanceSlot,
  );
  // A recorded origin is this slot's browser identity and wins over the current
  // rotation, so a restart resumes the stored session. It is trusted only from
  // the same client environment and only while it stays an origin the Portal in
  // use can accept.
  final port = recorded != null &&
          recorded.environment == clientEnvironment.trim() &&
          candidates.contains(recorded.port)
      ? recorded.port
      : candidates.first;
  if (!await isFree(port)) {
    throw StateError(
      'Web origin ${sanadDevWebOriginForPort(port)} is already in use. Stop the '
      'process holding it, or set $sanadDevWebPortEnvironmentKey to a free port '
      'the deployment registers for $clientEnvironment.',
    );
  }
  if (recorded == null ||
      recorded.port != port ||
      recorded.environment != clientEnvironment.trim()) {
    await writeSanadDevWebOriginRecord(
      sanadHome: sanadHome,
      clientInstanceSlot: clientInstanceSlot,
      environment: clientEnvironment.trim(),
      port: port,
    );
  }
  return port;
}

/// One recorded origin for a Home and Client slot.
class SanadDevWebOriginRecord {
  const SanadDevWebOriginRecord({
    required this.environment,
    required this.port,
  });

  final String environment;
  final int port;
}

String sanadDevWebOriginRecordPath(String sanadHome) => [
  sanadHome.replaceAll(RegExp(r'[\\/]+$'), ''),
  'dev',
  sanadDevWebOriginRecordName,
].join(Platform.pathSeparator);

String _slotKey(String? clientInstanceSlot) {
  final slot = clientInstanceSlot?.trim() ?? '';
  return slot.isEmpty ? 'primary' : slot;
}

/// Last origin this Home served for [clientInstanceSlot], if any.
Future<SanadDevWebOriginRecord?> readSanadDevWebOriginRecord({
  required String sanadHome,
  String? clientInstanceSlot,
}) async {
  final file = File(sanadDevWebOriginRecordPath(sanadHome));
  if (!await file.exists()) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    final slots = decoded['slots'];
    if (slots is! Map) return null;
    final entry = slots[_slotKey(clientInstanceSlot)];
    if (entry is! Map) return null;
    final environment = entry['environment'];
    final port = entry['port'];
    if (environment is! String || port is! int) return null;
    return SanadDevWebOriginRecord(environment: environment, port: port);
  } on FormatException {
    // A hand-edited or truncated record only loses the preference.
    return null;
  }
}

/// Records [port] so the next restart of this Home and slot reuses the origin.
Future<void> writeSanadDevWebOriginRecord({
  required String sanadHome,
  required String? clientInstanceSlot,
  required String environment,
  required int port,
}) async {
  final file = File(sanadDevWebOriginRecordPath(sanadHome));
  final slots = <String, Object?>{};
  if (await file.exists()) {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['slots'] is Map) {
        slots.addAll(
          Map<String, Object?>.from(decoded['slots'] as Map),
        );
      }
    } on FormatException {
      // Rebuilding a corrupt record is safer than failing the launch.
    }
  }
  slots[_slotKey(clientInstanceSlot)] = {
    'environment': environment,
    'port': port,
  };
  await secureRuntimeAtomicWrite(
    sanadHome,
    file.path,
    '${jsonEncode({'version': 1, 'slots': slots})}\n',
  );
}

/// Pins a Web Client's browser origin on the flutter command line.
///
/// Inherited values are removed first, so the launcher can reapply the origin
/// for an additional or restarted Web Client instead of duplicating it. Native
/// devices receive neither argument: their authentication uses a loopback
/// callback with an ephemeral port.
void applySanadDevWebPort(
  List<String> arguments, {
  required String device,
  required int? port,
}) {
  _removeWebOriginArguments(arguments);
  if (!isSanadDevWebDevice(device)) return;
  if (port == null) {
    throw StateError(
      'A Web Client requires a stable Web origin; no port was resolved.',
    );
  }
  arguments.add('$sanadDevWebPortArgument$port');
  arguments.add('$sanadDevWebHostnameArgument$sanadDevWebHostname');
}

/// Drops `--web-port`/`--web-hostname` in either `--flag=value` or `--flag value`
/// form, so an inherited or hand-written origin is replaced, never duplicated.
void _removeWebOriginArguments(List<String> arguments) {
  const valueFlags = [sanadDevWebPortArgument, sanadDevWebHostnameArgument];
  const bareFlags = ['--web-port', '--web-hostname'];
  for (var index = arguments.length - 1; index >= 0; index--) {
    final argument = arguments[index];
    if (valueFlags.any(argument.startsWith)) {
      arguments.removeAt(index);
      continue;
    }
    if (!bareFlags.contains(argument)) continue;
    arguments.removeAt(index);
    if (index < arguments.length && !arguments[index].startsWith('--')) {
      arguments.removeAt(index);
    }
  }
}

/// What the launch says about the origin it will serve.
class SanadDevWebOriginLaunch {
  const SanadDevWebOriginLaunch({required this.port, required this.warnings});

  final int? port;

  /// Operator-facing observations. Never a reason to abandon the launch: a Web
  /// Client is legitimate in every environment, and only the Portal decides
  /// whether a sign-in can complete.
  final List<String> warnings;
}

/// Resolves and reports the origin of one Web Client launch.
///
/// It chooses the port, prints the origin once, probes the Portal's own CORS
/// preflight for it, and returns guidance instead of blocking. The only failure
/// is a Web domain with no free origin at all, which cannot be launched.
Future<SanadDevWebOriginLaunch> prepareSanadDevWebOriginLaunch({
  required File configFile,
  required SanadCloudEndpoints? cloudEndpoints,
  required String sanadHome,
  required Map<String, String> processEnvironment,
  String? clientInstanceSlot,
  Future<bool> Function(int port)? portIsFree,
  Future<bool?> Function(String portalUrl, String origin)? probePortal,
}) async {
  final String clientEnvironment;
  try {
    clientEnvironment =
        cloudEndpoints?.environment ?? readSanadClientEnvironment(configFile);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    return SanadDevWebOriginLaunch(port: null, warnings: [error.message]);
  } on FileSystemException catch (error) {
    final message = 'Client configuration is unreadable: ${error.path}';
    stderr.writeln(message);
    return SanadDevWebOriginLaunch(port: null, warnings: [message]);
  }
  final portalUrl = cloudEndpoints?.portalUrl ?? '';
  final int port;
  try {
    port = await chooseSanadDevWebPort(
      sanadHome: sanadHome,
      clientEnvironment: clientEnvironment,
      portalUrl: portalUrl,
      processEnvironment: processEnvironment,
      clientInstanceSlot: clientInstanceSlot,
      portIsFree: portIsFree,
    );
  } on StateError catch (error) {
    stderr.writeln(error.message);
    return SanadDevWebOriginLaunch(port: null, warnings: [error.message]);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    return SanadDevWebOriginLaunch(port: null, warnings: [error.message]);
  }

  final origin = sanadDevWebOriginForPort(port);
  print('Web origin: $origin');
  final warnings = <String>[];
  final hosted =
      sanadDevWebOriginAuthorityFor(portalUrl) ==
      SanadDevWebOriginAuthority.hostedPortal;
  if (hosted) {
    // CORS already allows this loopback origin, so the launch is legitimate; the
    // remaining gate is the Portal's own Web redirect_uri registration, which a
    // localhost page cannot satisfy. Say so once, and name the supported path.
    warnings.add(
      'Web sign-in against $portalUrl completes only from the deployed Web app. '
      'Local Web sign-in uses the local Docker stack: '
      'sanad-dev run client -d chrome --config config/local.json, whose Portal '
      'registers $origin. This launch continues; it serves pre-login UI work.',
    );
  }
  if (!hosted && portalUrl.isNotEmpty) {
    final accepts = await (probePortal ??
            (String url, String candidate) =>
                probeSanadDevPortalWebOrigin(portalUrl: url, origin: candidate))(
      portalUrl,
      origin,
    );
    if (accepts == false) {
      warnings.add(
        'The local Portal at $portalUrl rejected this origin. Register it with '
        'SANAD_PORTAL_WEB_CLIENT_ORIGIN=$origin, '
        'SANAD_PORTAL_CORS_ORIGINS=<existing>,$origin, and '
        'BACKEND_CORS_ORIGINS, then recreate the Portal.',
      );
    }
  }
  for (final warning in warnings) {
    stderr.writeln(warning);
  }
  return SanadDevWebOriginLaunch(port: port, warnings: warnings);
}

/// Asks the Portal whether it would accept a browser request from [origin].
///
/// This is the browser's own credentialed CORS preflight, unauthenticated and
/// side-effect free: it starts no transaction and carries no credential. The
/// answer is advisory guidance for the launch, never ownership or liveness.
/// `null` means the Portal could not be asked, never that it said no.
Future<bool?> probeSanadDevPortalWebOrigin({
  required String portalUrl,
  required String origin,
  Duration timeout = const Duration(milliseconds: 1500),
}) async {
  final parsed = Uri.tryParse(portalUrl.trim());
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) return null;
  final basePath = parsed.path.replaceAll(RegExp(r'/+$'), '');
  final target = parsed.replace(path: '$basePath/auth/client/transactions');
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.openUrl('OPTIONS', target).timeout(timeout);
    request.headers.set('origin', origin);
    request.headers.set('access-control-request-method', 'POST');
    request.headers.set('access-control-request-headers', 'content-type');
    final response = await request.close().timeout(timeout);
    await response.drain<void>().timeout(timeout);
    if (response.statusCode >= 400) return false;
    final allowed = response.headers.value(
      HttpHeaders.accessControlAllowOriginHeader,
    );
    if (allowed == null) return false;
    return allowed.trim() == origin;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}
