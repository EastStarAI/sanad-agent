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
    test('the embedded loopback fixture is still valid', () {
      // The leaf expires on 2028-10-14. Rot silent into a handshake failure is
      // avoided by failing here first with the regeneration recipe.
      expect(
        DateTime.now().toUtc().isBefore(DateTime.utc(2028, 10, 14)),
        isTrue,
        reason:
            'Regenerate the embedded loopback fixture (see '
            '_generateCertificateAuthority); it expired 2028-10-14.',
      );
    });
    late HttpServer server;
    late String authorityPath;
    late List<int> agentBytes;

    setUp(() async {
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
          // The hosted fallback would be a real network call, and these tests
          // assert the refusal itself rather than the fallback path.
          fallbackManifestUri: null,
          // No bundle: the loopback authority must be refused.
          client: createReleaseTrustHttpClient(environment: const {}),
        );

        final result = await installer.install(targetVersion: '1.1.0');

        expect(result.status, AgentBootstrapStatus.tlsTrustFailed);
        expect(result.message, isNull);
        expect(target.existsSync(), isFalse);
      },
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
          fallbackManifestUri: null,
          client: createReleaseTrustHttpClient(
            environment: {extraCaBundleEnvironmentVariable: authorityPath},
          ),
        );

        final result = await installer.install(targetVersion: '1.1.0');

        expect(result.status, AgentBootstrapStatus.installed);
        expect(await target.readAsBytes(), agentBytes);
      },
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

/// A localhost authority and the leaf it issued, embedded as base64.
///
/// Embedded rather than generated at test time so the decisive assertions never
/// depend on an external `openssl` binary. A skip-on-missing gate is not
/// acceptable: on a Windows machine without Git's tools it silently skipped
/// exactly the two tests the Windows evidence rests on, so the suite reported
/// success while proving nothing.
///
/// The leaf is deliberately short-lived because macOS refuses a TLS server
/// certificate whose validity exceeds 825 days, and the authority is a
/// throwaway fixture with no production relationship that is reachable only
/// over loopback. `the embedded loopback fixture is still valid` fails with a
/// regeneration instruction before expiry can turn these assertions into a
/// confusing handshake error.
///
/// Regenerate with (leaf ≤ 825 days, SAN for both localhost and 127.0.0.1):
///
/// ```
/// openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 7300 \
///   -keyout ca.key -out ca.pem -config ca.cnf
/// openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr \
///   -config leaf.cnf
/// openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
///   -days 700 -out leaf.pem -extfile leaf.cnf -extensions v3
/// ```
({
  String certificate,
  String leafCertificate,
  String leafKey,
})
_generateCertificateAuthority(Directory directory) {
  String materialise(String name, String base64Body, String label) {
    final path = '${directory.path}/$name';
    File(path).writeAsStringSync(
      '-----BEGIN $label-----\n'
      '${_pemBody(base64Body)}\n'
      '-----END $label-----\n',
    );
    return path;
  }

  return (
    certificate: materialise('sanad-fixture-authority.pem', _authorityBody, 'CERTIFICATE'),
    leafCertificate: materialise('sanad-fixture-leaf.pem', _leafBody, 'CERTIFICATE'),
    leafKey: materialise('sanad-fixture-leaf-key.pem', _leafKeyBody, 'PRIVATE KEY'),
  );
}

String _pemBody(String body) {
  final buffer = StringBuffer();
  for (var index = 0; index < body.length; index += 64) {
    final end = index + 64 > body.length ? body.length : index + 64;
    buffer.writeln(body.substring(index, end));
  }
  return buffer.toString().trimRight();
}

const String _authorityBody =
  'MIIC/zCCAeegAwIBAgIUWG7KUw091TvbhKdxwV7hwwVv0S8wDQYJKoZIhvcNAQELBQAwJzElMCMG'
  'A1UEAwwcU2FuYWQgVGVzdCBSZWxlYXNlIEF1dGhvcml0eTAeFw0yNjExMTQyMjU1MDFaFw00NjEx'
  'MDkyMjU1MDFaMCcxJTAjBgNVBAMMHFNhbmFkIFRlc3QgUmVsZWFzZSBBdXRob3JpdHkwggEiMA0G'
  'CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDFfIOuyrUdKsqJg2Xf6HcVtHVFk0ybVaDoPDS0reOz'
  'H/aOdAtf7mNnqKjwA3ndtU2nQEVLE+Voz7ehKhegyEdkL+pyd1BSWAQkGPqpN5dbkhhUXGWUWdV5'
  'FqGbRTR8qg7PX/CLYGkq6mRv1MDSyxQyliiXXUnjDlPtVA3pGca0ZZ9lB7Rj8CC+/IJ2z890GVYw'
  'flzIiZq3gRL8Yf2jqBDOqIk9JDp8vRTehvNJFBfCiQJCJgk11Xnfi71PKzoUljoF7R21DrW2ZeKI'
  'cZODlutMIPnCvNq2ErYsDpR7uox830qqLWvDsbBjO/4eAvHERtkHsxSCH6f+zZWomq3emWVjAgMB'
  'AAGjIzAhMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMA0GCSqGSIb3DQEBCwUAA4IB'
  'AQBhBgmtsQBV3rsQS4zHQn3dEIreXbrzYRf8NYgoqF1YH6y0A2sP4o+Y6ScR3o5C4xcI8+IvVoZq'
  'rpryVwTAodfFjsPSDEik2FJ5K8qOIKGJit2TVHBDjVHjmu7LFvYyZLaBaV3fWku9oP40EEyVKfIv'
  'yq4mif+smBJia5bAfGTnXCRvhCKroak5nlgJLUW5TJEU6XIACC8aFOz1QGK4ksTdr2B2dQDwMOMz'
  'FllQDW4L3LF29H3u1yj7RcnX8uD9vc9QvfkSyeRCDIDEE+Gk5z+PomFap1vMcXW3iu5qzMamuARu'
  '2qnOkOjDXBzrSMtonfAJ2sW9fKipTHqvL1Yh0n+T';

const String _leafBody =
  'MIIDGjCCAgKgAwIBAgIUCjDLxbW7t8QgV+dkwvDAadPbxlAwDQYJKoZIhvcNAQELBQAwJzElMCMG'
  'A1UEAwwcU2FuYWQgVGVzdCBSZWxlYXNlIEF1dGhvcml0eTAeFw0yNjExMTQyMjU1MDJaFw0yODEw'
  'MTQyMjU1MDJaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCC'
  'AQoCggEBAMjcqT+7S3hzn/8FxwD0oMNTnI7VQprBVM2GSpCH4ZHKvN9PKPT84O8goEPWTDfcyUjg'
  '01rVytuMe2OWBxnzEykE50Q+pmVoxQStk29kZD7RenMvWC62c+KMeBcLFBx3F2bt+qJ+rbqXxQFd'
  'z733oTDofIb0cfuQkKrNML3bjV5xwKYycZ586A8u9YfEq0wFgmF5Cmr0BWVm91jpH1N+Go62pbwS'
  'CndnQ934fSkPcI9tks1MYINM2nwjkQOIMs3H/cORrot+hoh5uWF+1o1S+91RkzwcIqUeoOxUW18L'
  'R3PpqdUx7V0QKZVHxxNcxcxADc+l/sBnEG5vrpgwDc8w41UCAwEAAaNRME8wGgYDVR0RBBMwEYIJ'
  'bG9jYWxob3N0hwR/AAABMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoG'
  'CCsGAQUFBwMBMA0GCSqGSIb3DQEBCwUAA4IBAQAEo68yQoqzbswKwPkoybeC6bZNKxy/9aLgz7yr'
  'RnLXe0IS+Z5BpZ9sn/cx0cXxXOk3HIbHDXFt9U/sxeu+7Oti0pCu3RgmYNs7MjpHmYAvtIcCekd9'
  '4LfzrjlzS5efvH0v4Hz/2jQM0LQ5R0gapVOCN4s8uOztFobwtwYI2OqOQYUCa57gJ7KIS+hUGc7a'
  'UMgJVskL0XwyCFLBW4QKXJJStU/bgM+svuF9UCNDVcnEzsxdYFXmncQHlM6ZxTgsU7b3SrcqSdj7'
  '5MROjcSxZp30muFG30P9zAFQ3WbA3MTIdU31vlfR/7JXizMBoeLVhmny8cnl/+75Q7nFTy3kHE/2';

const String _leafKeyBody =
  'MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDI3Kk/u0t4c5//BccA9KDDU5yO'
  '1UKawVTNhkqQh+GRyrzfTyj0/ODvIKBD1kw33MlI4NNa1crbjHtjlgcZ8xMpBOdEPqZlaMUErZNv'
  'ZGQ+0XpzL1gutnPijHgXCxQcdxdm7fqifq26l8UBXc+996Ew6HyG9HH7kJCqzTC9241eccCmMnGe'
  'fOgPLvWHxKtMBYJheQpq9AVlZvdY6R9TfhqOtqW8Egp3Z0Pd+H0pD3CPbZLNTGCDTNp8I5EDiDLN'
  'x/3Dka6LfoaIeblhftaNUvvdUZM8HCKlHqDsVFtfC0dz6anVMe1dECmVR8cTXMXMQA3Ppf7AZxBu'
  'b66YMA3PMONVAgMBAAECggEALiuuyeQLGpJ1diEFV/5jT9LR23FBAKKtFBso26UoYCNam/gtwXa5'
  'W65DuKQzW+nn6NUpMCmRmjrmCAOt+TSLNHQYlvLRu+DD3OnrSIEqm9f6Di0VV5N/+tTwK9fTlSF4'
  '4yOT57M3yvrlAYXnYVLhHgVqzni1FK7r2h8Vc6bajZkuc/Uxhs34+wVXom6sGkCfnPTvWqivVdFm'
  'KVuzuXNh5UaDnknULbbqwnUCGhf3hGj4LD5PbedB1vDYKdSj2W3vHF+Av3rbIgukghorWW5nBoZJ'
  'obAfOn5NhJGM1Oa9ewslPmM37M/i8EBVQgYBU7TisNRI7ZNPu28nk7kyAv+SsQKBgQD7N2CkAT1I'
  'J1g/wuXTBB+ePpLBwl8UTSj61TjwVFGTpt3Sehzy5w46FMDagm/gigEQFAY6MulO7gnqrI7c4XLW'
  'ooe3FelpnGz0OwmgbhqR1FQ+mym2mpu4gWH9o8f5caofEUZf6ZqZ6k3xWDV3xch93+D9YxMmVr+k'
  'Jpn1ggGq7QKBgQDMr9FLK+SNFdfnyyLLC0uGDMgUt0wvDaSEgFNn2KOe5d5mo1CI/tAjZcH82eRM'
  'vuI5Tsrd4AytoeLX+Z1P8LQjSrJhLT9aVq4UtcdgUubwa/R3PI+93P5VCNVELIhRVa9C9VRjo0Px'
  's5qi+UCNIsiDUt48h7bYjQwe0jLh4FBFCQKBgEjpSK4xAeVILg/LdEKrZrXZ+WQtEsVko6kxa2Yt'
  'QsP04VquQGqrbvCih1qkEu57f1V4Slpn3lkfM1eeH5SyBk+POo6D2Ivjb6fu3ptmeWWr14uYIyIx'
  'e1Kwko04FNksCTEdJWy+8zUK0PZkIJiTmd4WtUk1kSBGezacUYD066D9AoGBAI1JCumdaYwtOLPJ'
  '1sFakY39ApqyD0cnXpkLTwcOVZqXxtUIA84cPSVB1w4mhNyoodS223cdcQLlDITRytFkL6NwqwJC'
  'zkkYLd8jvnRxpPDtQ3iOeBWxFmkxyKvfJVUnFOveFZsVFhAfTi0SaYlCKi/jon0bnI2LhoM7yl15'
  'jU6pAoGBALD1Ib1C1+9dtZaK7fV5YBtTyUWsu9uI+aJMZNqVtk95VApoy+vBFaLANAbASm4jyy/c'
  'wKJVBGFWAvqTlCcq26ZzitFaJBCL/q9DerSwBb1DaRZWS/jlfhFj12eGX8wFjuUgY4BT33lGHEDF'
  'iag9VUbIuH9rM8Z5ayqVg4bWJWY5';
