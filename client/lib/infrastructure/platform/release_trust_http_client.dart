import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:logging/logging.dart';

/// Names a PEM bundle of additional trusted roots for release fetches.
///
/// On Windows and Linux the Dart SDK verifies release hosts against a bundled
/// Mozilla root list instead of the platform store, so an antivirus or proxy
/// that inspects TLS fails those requests with `unable to get local issuer
/// certificate`. This variable lets the machine's owner trust that one
/// interception root explicitly.
///
/// The bundle is additive: platform roots stay trusted and the release payload
/// keeps its version, size, SHA-256, and platform-trust requirements. It never
/// disables certificate verification.
const String extraCaBundleEnvironmentVariable = 'SANAD_EXTRA_CA_BUNDLE';

final _logger = Logger('ReleaseTrustHttpClient');

/// Creates the HTTP client used to fetch release metadata and artifacts.
///
/// When no bundle is configured this is the ordinary client. A bundle that
/// cannot be read or parsed is reported and ignored rather than aborting an
/// install, because the request still verifies against the platform roots.
http.Client createReleaseTrustHttpClient({
  String? extraCaBundlePath,
  Map<String, String>? environment,
}) {
  // Web has no `SecurityContext` and never installs a local Agent.
  if (kIsWeb) return http.Client();

  final configured =
      extraCaBundlePath ?? (environment ?? Platform.environment)[extraCaBundleEnvironmentVariable];
  final path = configured?.trim();
  if (path == null || path.isEmpty) return http.Client();

  try {
    final context = SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificates(path);
    _logger.info(
      'Release fetches also trust the bundle named by '
      '$extraCaBundleEnvironmentVariable.',
    );
    return IOClient(HttpClient(context: context));
  } on Object catch (error) {
    // Never echo the path: it is user-machine state, not diagnostics.
    _logger.warning(
      'Ignoring $extraCaBundleEnvironmentVariable: the bundle could not be '
      'loaded (${error.runtimeType}). Platform roots remain in effect.',
    );
    return http.Client();
  }
}
