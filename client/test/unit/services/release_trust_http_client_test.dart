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
    test('the embedded loopback fixture is inside its validity window', () {
      // Absolute dates, so a skewed generating clock can never reintroduce a
      // future-dated fixture: both bounds fail loudly with the recipe.
      final now = DateTime.now().toUtc();
      expect(
        now.isAfter(DateTime.utc(2025, 11, 1)) && now.isBefore(DateTime.utc(2028, 1, 1)),
        isTrue,
        reason:
            'Regenerate the embedded loopback fixture (see '
            '_generateCertificateAuthority); it is valid 2025-11-01 to '
            '2028-01-01 and must be replaced before that window closes.',
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
/// Both certificates carry **explicit calendar validity**, never `-days`. A
/// relative window is stamped from the generating process's clock and timezone;
/// with `TZ` unset, `openssl` writes local wall time as UTC, which produced a
/// fixture dated two hours in the future. The suite then failed with
/// `certificate is not yet valid` on every machine whose clock was correct,
/// which is exactly how an earlier revision of this fixture shipped broken. The
/// leaf is also kept under 825 days because macOS refuses a TLS server
/// certificate with a longer validity.
///
/// Regenerate with `openssl ca`, whose `-startdate`/`-enddate` are absolute:
///
/// ```
/// openssl ca -batch -selfsign -config ca.cnf -keyfile ca.key -in ca.csr \
///   -out ca.pem -startdate 20200101000000Z -enddate 20450101000000Z \
///   -extensions v3_ca
/// openssl ca -batch -config ca.cnf -in leaf.csr -out leaf.pem \
///   -startdate 20251101000000Z -enddate 20280101000000Z \
///   -extensions v3_leaf
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
  'MIIC7TCCAdWgAwIBAgICEAAwDQYJKoZIhvcNAQELBQAwJzElMCMGA1UEAwwcU2FuYWQgVGVzdCBS'
  'ZWxlYXNlIEF1dGhvcml0eTAeFw0yMDAxMDEwMDAwMDBaFw00NTAxMDEwMDAwMDBaMCcxJTAjBgNV'
  'BAMMHFNhbmFkIFRlc3QgUmVsZWFzZSBBdXRob3JpdHkwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAw'
  'ggEKAoIBAQCqRKkvCegz+9+i29Ji0xh1dnpzn/i951h3fsV2ld1raitV6ljP+TfeOijDfdWIn5aM'
  'WTqVvoFJhVUqa+pS+9Nr7E9yMbPvB+6Ijh5w/ON4QXybwiqSnGUi4eeDseINpWMe9jUnkVkifg7I'
  'TXU8I1l54Ch4iWXOhSXAOP0WeZhjgwsepqL5B0sC4pK8I0LiGZDZTq/qBBBbdkvqG86aZgUQgN2A'
  'a/jHnVV/ttXgmoAqAPDFThHMBVBU4odzgMxmG9kQ1CjFYK+YbJZaxKu4mEEc4tc65/mCxK4DmW0A'
  'N7QI6tWkGCawZvwjA8Pd18FftDFFeqsEWk6HLdNFrkr2l8ZlAgMBAAGjIzAhMA8GA1UdEwEB/wQF'
  'MAMBAf8wDgYDVR0PAQH/BAQDAgEGMA0GCSqGSIb3DQEBCwUAA4IBAQBGf/Siq8lan1RN/QJnRGlm'
  'UwR3ljB3SkbB0cdo7WrGf4FMVXnpb9/mpAJjOA18MbXxzGmRzXNUGgo0vL6b/Ga/pWYnkkktqM5D'
  '52QZUT2hoXeYtxzmsQ01SvWNS/rv+ZISAFqf9li0Q+HvpNzQWJb4cS2aPkobpGOqVP7RCWmQKq7z'
  'ThYJ2wY/DDZF+tJFwZeygDMQC0jhtHreNo0+scFivD2VIVlg6hevglGXw/WLRUqm1oojBNU/9LBE'
  'Gvgrn7knX4x+pQjoUUIl944GfLojMRvcV5NJBCb3AEU41Uk4HFAkN1jdnzBEid/sTmKweIH/k5Y0'
  'iY3hzFgzxrzuV9tx';

const String _leafBody =
  'MIIDCDCCAfCgAwIBAgICEAEwDQYJKoZIhvcNAQELBQAwJzElMCMGA1UEAwwcU2FuYWQgVGVzdCBS'
  'ZWxlYXNlIEF1dGhvcml0eTAeFw0yNTExMDEwMDAwMDBaFw0yODAxMDEwMDAwMDBaMBQxEjAQBgNV'
  'BAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJVUjDhozM8BCnP0'
  'TcfXk5YJO9pIYND1DzYAd25lv6f4cOuHpz8zycgkAZjCWe2PFTc/Ze4KOE1BDQHhVV7U6k0dsbvS'
  'NHofMnVZOsOkUAYSzC3dTsAK6VX8s2vOeUQbO5KamPf94ntTh2H0gyI2lrv6dmLzqJA1FpFz2i1u'
  'ayYulOgXr+ZzXC8YKv0uYbgAGVL3Rq0QSoUv2CAPJN6b6hLHIcVAl7cgLnfZX4PQd70jzNK9sqYR'
  'yfePDFW09cU11JXH+cU7GHWcF8qD0UyhZjApB+UC4HDch09hUODxobK2+kgxLGIASJswwgymUvgM'
  '3b8nFP5y+y6yg7pmcw7y1ncCAwEAAaNRME8wGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMAwG'
  'A1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMA0GCSqGSIb3'
  'DQEBCwUAA4IBAQCSUpka+wrN0kTjY4ik6vwB8q7QZgwPw4lm46eRFRm5hygy1iwSm5r/sUbOb91/'
  'su4jm335c8yeys7ghV+Y+Owm5eSFt4Pongp2LlK54UmoYESriJBHz3dzYtaRw3hl/diLj3kxIgaU'
  'SvJnf2t+M6v+sD4TVbiOHgukk3xKoiPWjckvBf6GZTBS9oZRG9JR6ApyySHVquNOgcqDi2VuD3qx'
  'mncN7FquvDZjCtSpoaGE51KzMxTq/GPPMktUlJ1IdckWaOaNjmWC1x6r01yGBtGdK5nt2LlhrG1H'
  'E7mdrwEyWI1KOt/Qbj9mevz4Je6zaNxbVcPmcaTQOZLMrvLxgW1n';

const String _leafKeyBody =
  'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCVVIw4aMzPAQpz9E3H15OWCTva'
  'SGDQ9Q82AHduZb+n+HDrh6c/M8nIJAGYwlntjxU3P2XuCjhNQQ0B4VVe1OpNHbG70jR6HzJ1WTrD'
  'pFAGEswt3U7ACulV/LNrznlEGzuSmpj3/eJ7U4dh9IMiNpa7+nZi86iQNRaRc9otbmsmLpToF6/m'
  'c1wvGCr9LmG4ABlS90atEEqFL9ggDyTem+oSxyHFQJe3IC532V+D0He9I8zSvbKmEcn3jwxVtPXF'
  'NdSVx/nFOxh1nBfKg9FMoWYwKQflAuBw3IdPYVDg8aGytvpIMSxiAEibMMIMplL4DN2/JxT+cvsu'
  'soO6ZnMO8tZ3AgMBAAECggEAGsR2hBAJElwR5xoWLSnP2zeZgnWx4RLkYJ4xylizw6StfRKqYJJk'
  'a5tErAC+hO4+c9JJ76LmV7a+4aTmHCMXQq59cvjpjjB0Z4OQnIwiCgypi9kdKiBqlg6/jKYMp7An'
  '/A35OI7KX6fn3x+ot+PIHjb1rKQXhY32lykIpVcjHss5mqnfDXmmUErR6cMWpTZcun50gqrmKgJE'
  'pZrRL8F9OOHRcoZaW5D/IXaol4dqKixQuLdUmzlwIqtTyFUUEC1CHEopC40Wl8bA6w7bn99PAb08'
  'sZQhVLqFCR3QF+CRxK/fXiaLfxavafAUWHNEBOVcC+z/bDYHKuZeMHVUGbu6TQKBgQDM7eM73Hdu'
  'Fx2wPcGX5Adbbwz3Rbyd/g2tc64qyNaOsmVOEs/AvDZoaJ+timrAoeSKYYVyY2JVBkelNDglr6Hk'
  'NDIcyhcQsf/rduip9bICxGd64v5um+siITuToYjvbumJbfFoxJgsxEyDkuxijyDu4dqOj+5TqKVU'
  '+C6E4LmmiwKBgQC6i4vbEwX4RZBp+iSjNM28nlzN99dz+t8e4DYpERTzxRTcnQNIoGHMix3jOEF+'
  'Me7RMHE4BZ+jkyOLnilwfRqjoRHzILqTikShhwHPqnb9rHNoGLIVkW9bfaXAQwBHBX8ZDXY9l4pr'
  'hMp1RT/DfkfBHfnqWpGcv8cCyVVIYvw5RQKBgEK6g2+OjmUOqeAle9BVs/+V3Yb28kAP5axBKslL'
  'tHGqrUoK3hNINf8xci00ESbAkIZu0uE4c2B0NwgYROAgnHqOdHLjazdIfqjRg1k0Y8563acqGucx'
  'ZhMq9xdPViOA3hKd9inDOjn5gWCmispdCMBAUsZxH42mMI/GcH9cHZeZAoGBALhWFxCXvsl0LF2c'
  '8sFX94nQz5I0u/H+0KaZFswD9jlg4dmTSmBlI99VBWa3+3fxbbXHccnTPMoOJwzbcMWYyk8xZiRj'
  'jhsngeRAHdkQ8N6Bn9UYujm36lt1UOopC0gjNVITTGlWq1DN+qZhlL3gtpUtwv0DHGrR0518SErs'
  'jaMlAoGAF8C4/NI/pdETjpAgsQCJmmYgLjT9zykAeJ6BAjIVOm20KSLxDNx/OncoPI4STDXK4WAq'
  'oANtN1+9jDdsVOWdzEMtNMt+03ntHuN+tuo90Z2S/z0BDL3UQxrks+xrx4gnECHumHgHRu5gNJBS'
  'IVdaJ1xlCO5BsB2twVIn3cjIdDI=';
