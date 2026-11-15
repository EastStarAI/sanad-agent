import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:logging/logging.dart';

/// Names a PEM bundle of additional trusted roots for release fetches.
///
/// Certificate verification needs the issuer of the release host's chain, and
/// `dart:io`/BoringSSL never fetches a missing intermediate itself. The Windows
/// Flutter engine reads the Windows certificate store (the engine embeds no root
/// list and imports `CertOpen*`), so a machine that lacks one intermediate of
/// the published chain — or that inspects TLS — refuses this request with
/// `unable to get local issuer certificate` while every OS-based client on the
/// same machine succeeds, because those clients complete the chain by fetching
/// the intermediate. This variable lets the machine's owner trust that root or
/// intermediate explicitly.
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
