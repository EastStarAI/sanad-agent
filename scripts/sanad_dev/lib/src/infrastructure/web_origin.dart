import 'dart:async';
import 'dart:io';

import 'cloud_endpoints.dart';
import 'runtime_context.dart';

/// Explicit override for the Web Client origin.
///
/// A derived origin is stable per Home, Client slot, and client environment, so
/// a deployment whose Portal already registers a different origin (for example
/// the local stack pinned to a specific port) keeps working by setting this.
const String sanadDevWebPortEnvironmentKey = 'SANAD_DEV_WEB_PORT';

/// First port of the reserved deterministic Web Client origin range.
const int sanadDevWebPortRangeStart = 52000;

/// Number of ports reserved for deterministic Web Client origins.
///
/// The range must stay disjoint from the Agent (`58085-58185`) and VM-service
/// (`51000-51999`) ranges so one runtime can never derive another's port.
const int sanadDevWebPortRangeSize = 1000;

/// Last port of the reserved deterministic Web Client origin range.
const int sanadDevWebPortRangeEnd =
    sanadDevWebPortRangeStart + sanadDevWebPortRangeSize - 1;

/// Host the Web Client is always served from.
///
/// flutter_tools defaults `--web-hostname` to `any`, which binds every
/// interface and only *reports* `localhost`. Naming the loopback host keeps the
/// browser origin deterministic and the dev server off the network.
const String sanadDevWebHostname = 'localhost';

/// flutter_tools option that pins the Web dev server port.
const String sanadDevWebPortArgument = '--web-port=';

/// flutter_tools option that pins the Web dev server host.
const String sanadDevWebHostnameArgument = '--web-hostname=';

/// Devices whose browser origin decides where the Web session is stored.
///
/// `web-server` is the manual-browser device: the origin matters exactly the
/// same way, but flutter_tools opens no browser and no Chrome profile applies.
bool isSanadDevWebDevice(String device) =>
    device == 'chrome' || device == 'web-server';

/// Browser origin served by the Web dev server on [port].
String sanadDevWebOriginForPort(int port) =>
    'http://$sanadDevWebHostname:$port';

/// Deterministic Web origin port for one Home, Client slot, and environment.
///
/// The same inputs always resolve to the same origin, which is what lets a
/// restarted Web Client resume the session stored under it. `environment`
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

/// Port a Web Client must be served from: the explicit override, else the
/// deterministic gap-free derivation.
///
/// There is deliberately no random fallback. A random port produces an origin
/// no Portal registration and no stored browser session can follow.
int resolveSanadDevWebPort({
  required String sanadHome,
  required String clientEnvironment,
  required Map<String, String> processEnvironment,
  String? clientInstanceSlot,
}) {
  final rawOverride =
      processEnvironment[sanadDevWebPortEnvironmentKey]?.trim() ?? '';
  if (rawOverride.isEmpty) {
    return deriveSanadDevWebPort(
      sanadHome: sanadHome,
      clientEnvironment: clientEnvironment,
      clientInstanceSlot: clientInstanceSlot,
    );
  }
  final port = int.tryParse(rawOverride);
  if (port == null || port < 1 || port > 65535) {
    throw FormatException(
      '$sanadDevWebPortEnvironmentKey must be a valid TCP port: $rawOverride',
    );
  }
  return port;
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

/// Refuses to start a Web Client whose port another process already owns.
///
/// A bound port means the derived origin cannot be served, so the launch would
/// fail inside flutter_tools with a less instructive message. There is no
/// fallback: a different port is a different origin and would silently drop the
/// stored session again.
Future<void> assertSanadDevWebPortAvailable({
  required int port,
  required String clientEnvironment,
}) async {
  try {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();
  } on SocketException {
    throw StateError(
      'Web origin ${sanadDevWebOriginForPort(port)} is already in use by '
      'another process. Stop it, or set $sanadDevWebPortEnvironmentKey to a '
      'free port and register that origin with the deployment that owns the '
      'Portal ($clientEnvironment).',
    );
  }
}

/// Result of resolving the origin one Web Client launch will be served from.
class SanadDevWebOriginLaunch {
  const SanadDevWebOriginLaunch.ready({required this.port})
    : refusal = null,
      exitStatus = 0,
      startupFailureReason = null;

  const SanadDevWebOriginLaunch.refused({
    required this.refusal,
    required this.exitStatus,
    required this.startupFailureReason,
  }) : port = null;

  final int? port;

  /// Operator-facing reason the launch must not continue.
  final String? refusal;

  /// CLI exit status that must accompany [refusal].
  final int exitStatus;

  /// Startup-attempt reason recorded with the refusal.
  final String? startupFailureReason;

  bool get isRefused => refusal != null;
}

/// Decides, prints, and refuses the Web origin of one launch.
///
/// The caller only has to ask before spawning: this resolves the client
/// environment and the deterministic port, proves the port is free, verifies the
/// Portal's allowlist, prints the origin once, and writes any refusal or warning
/// to stderr. A returned launch is never missing its origin.
Future<SanadDevWebOriginLaunch> prepareSanadDevWebOriginLaunch({
  required File configFile,
  required SanadCloudEndpoints? cloudEndpoints,
  required String sanadHome,
  required bool cloudEnabled,
  required Map<String, String> processEnvironment,
  String? clientInstanceSlot,
}) async {
  final String clientEnvironment;
  try {
    clientEnvironment =
        cloudEndpoints?.environment ?? readSanadClientEnvironment(configFile);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    return SanadDevWebOriginLaunch.refused(
      refusal: error.message,
      exitStatus: 64,
      startupFailureReason: 'client environment is invalid',
    );
  }

  final int port;
  try {
    port = resolveSanadDevWebPort(
      sanadHome: sanadHome,
      clientEnvironment: clientEnvironment,
      processEnvironment: processEnvironment,
      clientInstanceSlot: clientInstanceSlot,
    );
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    return SanadDevWebOriginLaunch.refused(
      refusal: error.message,
      exitStatus: 64,
      startupFailureReason: 'client web origin is invalid',
    );
  }

  final origin = sanadDevWebOriginForPort(port);
  try {
    await assertSanadDevWebPortAvailable(
      port: port,
      clientEnvironment: clientEnvironment,
    );
  } on StateError catch (error) {
    stderr.writeln(error.message);
    return SanadDevWebOriginLaunch.refused(
      refusal: error.message,
      exitStatus: 1,
      startupFailureReason: 'client web origin is unavailable',
    );
  }

  final portalUrl = cloudEndpoints?.portalUrl ?? '';
  final preflight = evaluateSanadDevWebOriginPreflight(
    origin: origin,
    portalUrl: portalUrl,
    cloudEnabled: cloudEnabled,
    deploymentAcceptsOrigin: cloudEnabled && portalUrl.isNotEmpty
        ? await probeSanadDevPortalWebOrigin(
            portalUrl: portalUrl,
            origin: origin,
          )
        : null,
  );
  if (preflight.isRefused) {
    stderr.writeln(preflight.message);
    return SanadDevWebOriginLaunch.refused(
      refusal: preflight.message,
      exitStatus: 1,
      startupFailureReason: 'client web origin cannot authenticate',
    );
  }
  if (preflight.isUnverified) stderr.writeln(preflight.message);
  print('Web origin: $origin');
  return SanadDevWebOriginLaunch.ready(port: port);
}

/// Who decides which browser origins may authenticate for this environment.
enum SanadDevWebOriginAuthority {
  /// The Portal is served on loopback by a deployment the developer owns, so
  /// its registered Web origin can be aligned with the derived origin.
  deploymentOwned,

  /// The Portal is hosted and registers exactly one HTTPS Web app origin, so a
  /// loopback origin can never complete sign-in.
  hostedPortal,
}

/// Outcome of the Web origin preflight.
enum SanadDevWebOriginPreflightOutcome { ready, unverified, refused }

/// One preflight decision plus the operator-facing explanation.
class SanadDevWebOriginPreflight {
  const SanadDevWebOriginPreflight(this.outcome, this.message);

  final SanadDevWebOriginPreflightOutcome outcome;
  final String message;

  bool get isRefused => outcome == SanadDevWebOriginPreflightOutcome.refused;

  bool get isUnverified =>
      outcome == SanadDevWebOriginPreflightOutcome.unverified;
}

/// Loopback Portal URLs are owned by a local deployment; anything else is the
/// hosted Portal whose Web registration is a single hosted app origin.
SanadDevWebOriginAuthority sanadDevWebOriginAuthorityFor(String portalUrl) {
  final host = Uri.tryParse(portalUrl.trim())?.host.toLowerCase() ?? '';
  const loopbackHosts = {'127.0.0.1', 'localhost', '::1'};
  return loopbackHosts.contains(host)
      ? SanadDevWebOriginAuthority.deploymentOwned
      : SanadDevWebOriginAuthority.hostedPortal;
}

/// Decides whether a Web Client launched at [origin] can ever authenticate.
///
/// [deploymentAcceptsOrigin] is the result of verifying the local Portal's own
/// CORS allowlist, or `null` when it could not be verified. The decision is pure
/// so the launch path stays testable without a network or a real Portal.
SanadDevWebOriginPreflight evaluateSanadDevWebOriginPreflight({
  required String origin,
  required String portalUrl,
  required bool cloudEnabled,
  required bool? deploymentAcceptsOrigin,
}) {
  if (!cloudEnabled) {
    return SanadDevWebOriginPreflight(
      SanadDevWebOriginPreflightOutcome.unverified,
      'Web origin pinned to $origin. The cloud gateway is disabled '
      '(--no-cloud), so this launch does not sign in; enable it to verify that '
      'the session persists.',
    );
  }
  if (sanadDevWebOriginAuthorityFor(portalUrl) ==
      SanadDevWebOriginAuthority.hostedPortal) {
    return SanadDevWebOriginPreflight(
      SanadDevWebOriginPreflightOutcome.refused,
      'Refusing to launch a Web Client at $origin: it can never sign in.\n'
      'The hosted Portal at $portalUrl registers exactly one HTTPS Web '
      'callback origin, served by the deployed Web app, so a loopback page is '
      'rejected by its CORS preflight and by the exact redirect_uri check '
      '("invalid_redirect_uri").\n'
      'Use a native device (-d macos) for a signed-in Client, or run '
      'config/local.json against the local stack, whose Portal Web origin this '
      'launcher pins and verifies. For pre-login UI work only, relaunch with '
      '--no-cloud so the origin is pinned without promising a sign-in.',
    );
  }
  if (deploymentAcceptsOrigin == false) {
    return SanadDevWebOriginPreflight(
      SanadDevWebOriginPreflightOutcome.refused,
      'Refusing to launch a Web Client at $origin: the local Portal at '
      '$portalUrl rejects that origin. Register it in the services that decide '
      'the browser origin:\n'
      '  SANAD_PORTAL_WEB_CLIENT_ORIGIN=$origin\n'
      '  SANAD_PORTAL_CORS_ORIGINS=<existing>,$origin\n'
      '  BACKEND_CORS_ORIGINS=[...,"$origin"]\n'
      'The Web callback is $origin/oauth/callback. Recreate the Portal and '
      'Backend, then relaunch.',
    );
  }
  if (deploymentAcceptsOrigin == null) {
    return SanadDevWebOriginPreflight(
      SanadDevWebOriginPreflightOutcome.unverified,
      'Web origin pinned to $origin, but $portalUrl did not answer the CORS '
      'preflight, so its allowlist could not be verified. If sign-in fails, '
      'register $origin (SANAD_PORTAL_WEB_CLIENT_ORIGIN and '
      'SANAD_PORTAL_CORS_ORIGINS plus BACKEND_CORS_ORIGINS) and compare the '
      'browser location.origin with it.',
    );
  }
  return const SanadDevWebOriginPreflight(
    SanadDevWebOriginPreflightOutcome.ready,
    '',
  );
}

/// Asks the Portal whether it would accept a browser request from [origin].
///
/// This is the browser's own credentialed CORS preflight, unauthenticated and
/// side-effect free: it starts no transaction and carries no credential. The
/// answer is advisory evidence for the preflight, never ownership or liveness.
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
