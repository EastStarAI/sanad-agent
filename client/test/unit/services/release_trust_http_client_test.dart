import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sanad_client/features/devices/data/daemon/verified_agent_bootstrap_installer.dart';
import 'package:sanad_client/infrastructure/platform/release_trust_http_client.dart';

/// Coverage for the release-fetch trust boundary.
///
/// Windows and Linux verify release hosts against the Mozilla roots bundled in
/// the Dart SDK, so a machine that inspects TLS (antivirus, corporate proxy, or
/// a partial root store) refuses the chain with `unable to get local issuer
/// certificate`. The Client must report that as its own outcome and must offer
/// one explicit, additive way to trust the interception root without ever
/// disabling verification.
void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'sanad-release-trust-test-',
    );
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  group('release trust client', () {
    test('an unset bundle leaves the default platform trust in place', () {
      final client = createReleaseTrustHttpClient(environment: const {});

      expect(client, isA<http.Client>());
      client.close();
    });

    test('a bundle path that does not exist is ignored, not fatal', () {
      final client = createReleaseTrustHttpClient(
        environment: const {
          extraCaBundleEnvironmentVariable:
              '/nonexistent/sanad-test-ca-bundle.pem',
        },
      );

      expect(client, isA<http.Client>());
      client.close();
    });

    test('a malformed bundle is ignored, not fatal', () async {
      final malformed = File('${temporaryDirectory.path}/broken.pem')
        ..writeAsStringSync('-----BEGIN CERTIFICATE-----\nnot base64\n');

      final client = createReleaseTrustHttpClient(
        environment: {extraCaBundleEnvironmentVariable: malformed.path},
      );

      expect(client, isA<http.Client>());
      client.close();
    });
  });

  group('loopback release host', () {
    late HttpServer server;
    late String authorityPath;
    late List<int> agentBytes;

    final skipReason = _opensslUnavailableReason();

    setUp(() async {
      if (skipReason != null) return;
      final authority = _generateCertificateAuthority(temporaryDirectory);
      authorityPath = authority.certificate;
      agentBytes = utf8.encode('verified-agent-over-tls');

      final context = SecurityContext()
        ..useCertificateChain(authority.leafCertificate)
        ..usePrivateKey(authority.leafKey);
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      server.listen((request) {
        final body = request.uri.path.endsWith('release-manifest.json')
            ? utf8.encode(
                jsonEncode(
                  _agentManifest(
                    size: agentBytes.length,
                    digest: sha256.convert(agentBytes).toString(),
                  ),
                ),
              )
            : agentBytes;
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.binary
          ..add(body);
        unawaited(request.response.close());
      });
    });

    tearDown(() async {
      if (skipReason != null) return;
      await server.close(force: true);
    });

    test(
      'a chain the platform roots refuse becomes a trust failure',
      () async {
        final target = File('${temporaryDirectory.path}/bin/sanad');
        final installer = VerifiedAgentBootstrapInstaller(
          targetPath: target.path,
          operatingSystem: 'linux',
          architecture: 'x64',
          manifestUri: Uri.parse(
            'https://127.0.0.1:${server.port}/release-manifest.json',
          ),
          // The manifest keeps canonical GitHub identity; only the bytes come
          // from the loopback host, exactly like an isolated artifact mirror.
          artifactMirrorUri: Uri.parse('https://127.0.0.1:${server.port}/'),
          // No bundle: the loopback authority must be refused.
          client: createReleaseTrustHttpClient(environment: const {}),
        );

        final result = await installer.install(targetVersion: '1.1.0');

        expect(result.status, AgentBootstrapStatus.tlsTrustFailed);
        expect(result.message, isNull);
        expect(target.existsSync(), isFalse);
      },
      skip: skipReason,
    );

    test(
      'an explicit bundle unblocks the same host without disabling verification',
      () async {
        final target = File('${temporaryDirectory.path}/bin/sanad');
        final installer = VerifiedAgentBootstrapInstaller(
          targetPath: target.path,
          operatingSystem: 'linux',
          architecture: 'x64',
          manifestUri: Uri.parse(
            'https://127.0.0.1:${server.port}/release-manifest.json',
          ),
          artifactMirrorUri: Uri.parse('https://127.0.0.1:${server.port}/'),
          client: createReleaseTrustHttpClient(
            environment: {extraCaBundleEnvironmentVariable: authorityPath},
          ),
        );

        final result = await installer.install(targetVersion: '1.1.0');

        expect(result.status, AgentBootstrapStatus.installed);
        expect(await target.readAsBytes(), agentBytes);
      },
      skip: skipReason,
    );
  });
}

Map<String, dynamic> _agentManifest({
  required int size,
  required String digest,
}) => {
  'schema_version': 1,
  'version': '1.1.0',
  'build_number': 2,
  'tag': 'v1.1.0',
  'commit': '1234567890abcdef',
  'channel': 'stable',
  'repository': 'EastStarAI/sanad-agent',
  'artifacts': [
    {
      'component': 'agent',
      'platform': 'linux',
      'architecture': 'x64',
      'format': 'executable',
      'filename': 'sanad-agent-1.1.0-linux-x64',
      'url': 'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0/sanad-agent-1.1.0-linux-x64',
      'sha256': digest,
      'size': size,
      'public': true,
      'signature_type': 'github-attestation',
    },
  ],
};

/// A localhost certificate authority and its leaf, generated at test time.
///
/// No PEM material is tracked: the repository ignores `*.pem` and `*.key` so
/// certificate material can never be committed by accident, and this fixture
/// only has to exist for the duration of one test process. The bundle handed to
/// the Client is the authority alone, exactly like an interception root whose
/// leaf is presented by the release host.
({
  String certificate,
  String leafCertificate,
  String leafKey,
})
_generateCertificateAuthority(Directory directory) {
  File config(String name, String body) =>
      File('${directory.path}/$name')..writeAsStringSync(body);

  final authorityConfig = config('authority.cnf', '''
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Sanad Test Authority
[v3]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
''');
  final leafConfig = config('leaf.cnf', '''
[req]
distinguished_name = dn
prompt = no
[dn]
CN = localhost
[v3]
subjectAltName = DNS:localhost,IP:127.0.0.1
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
''');

  final authorityKey = '${directory.path}/authority.key';
  final authorityPem = '${directory.path}/authority-cert.pem';
  final leafKey = '${directory.path}/localhost-key.pem';
  final leafRequest = '${directory.path}/localhost.csr';
  final leafPem = '${directory.path}/localhost-cert.pem';

  for (final arguments in [
    [
      'req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-nodes',
      '-days', '2', '-keyout', authorityKey, '-out', authorityPem,
      '-config', authorityConfig.path,
    ],
    [
      'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', leafKey,
      '-out', leafRequest, '-config', leafConfig.path,
    ],
    [
      'x509', '-req', '-in', leafRequest, '-CA', authorityPem,
      '-CAkey', authorityKey, '-CAcreateserial', '-days', '2',
      '-out', leafPem, '-extfile', leafConfig.path, '-extensions', 'v3',
    ],
  ]) {
    final result = Process.runSync('openssl', arguments);
    if (result.exitCode != 0) {
      throw StateError('openssl could not create the loopback certificate.');
    }
  }
  return (
    certificate: authorityPem,
    leafCertificate: leafPem,
    leafKey: leafKey,
  );
}

String? _opensslUnavailableReason() {
  try {
    final result = Process.runSync('openssl', ['version']);
    return result.exitCode == 0
        ? null
        : 'Requires the openssl CLI to mint a self-signed loopback certificate.';
  } on ProcessException {
    return 'Requires the openssl CLI to mint a self-signed loopback certificate.';
  }
}
