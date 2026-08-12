import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart';
import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:test/test.dart';

import '../support/memory_agent_secret_store.dart';

BigInt _bytesBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

bool _verifies(String proof, Map<String, String> jwk) {
  final parts = proof.split('.');
  final signatureBytes = base64Url.decode(base64Url.normalize(parts[2]));
  final domain = ECDomainParameters('prime256v1');
  final publicKey = ECPublicKey(
    domain.curve.createPoint(
      _bytesBigInt(base64Url.decode(base64Url.normalize(jwk['x']!))),
      _bytesBigInt(base64Url.decode(base64Url.normalize(jwk['y']!))),
    ),
    domain,
  );
  final verifier = Signer('SHA-256/ECDSA')
    ..init(false, PublicKeyParameter<ECPublicKey>(publicKey));
  return verifier.verifySignature(
    Uint8List.fromList(utf8.encode('${parts[0]}.${parts[1]}')),
    ECSignature(
      _bytesBigInt(signatureBytes.sublist(0, 32)),
      _bytesBigInt(signatureBytes.sublist(32)),
    ),
  );
}

Map<String, dynamic> _jwtPart(String proof, int index) {
  return jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(proof.split('.')[index])),
        ),
      )
      as Map<String, dynamic>;
}

void main() {
  test('default Agent display names never expose hostnames or addresses', () {
    expect(defaultAgentDeviceName('macos'), 'Sanad Agent (macOS)');
    expect(defaultAgentDeviceName('linux'), 'Sanad Agent (Linux)');
    expect(defaultAgentDeviceName('windows'), 'Sanad Agent (Windows)');
    expect(defaultAgentDeviceName('other'), 'Sanad Agent (Unknown OS)');
  });

  late Directory home;
  late MemoryAgentSecretStore secrets;

  setUp(() {
    home = Directory.systemTemp.createTempSync('sanad-device-authorization-');
    secrets = MemoryAgentSecretStore();
    setSanadHomeOverride(home.path);
    setSanadStateHomeOverride(home.path);
  });

  tearDown(() {
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test(
    'P-256 identity persists and signs bounded token/gateway proofs',
    () async {
      final first = await DeviceKeyIdentity.loadOrCreate(secretStore: secrets);
      final second = await DeviceKeyIdentity.loadOrCreate(secretStore: secrets);

      expect(second.thumbprint, first.thumbprint);
      expect(second.publicJwk, first.publicJwk);
      expect(secrets.values[DeviceKeyIdentity.privateKeyEntry], isNotEmpty);
      expect(File('${home.path}/device_identity.json').existsSync(), isFalse);
      expect(first.publicJwk['kty'], 'EC');
      expect(first.publicJwk['crv'], 'P-256');

      final tokenProof = await first.deviceTokenProof(
        Uri.parse('https://portal.test/auth/device/token'),
        'synthetic-device-code',
      );
      expect(_verifies(tokenProof, first.publicJwk), isTrue);
      final tokenHeader = _jwtPart(tokenProof, 0);
      final tokenPayload = _jwtPart(tokenProof, 1);
      expect(tokenHeader['alg'], 'ES256');
      expect(tokenHeader['typ'], 'dpop+jwt');
      expect(tokenHeader.toString(), isNot(contains('private')));
      expect(tokenPayload['htm'], 'POST');
      expect(tokenPayload['htu'], 'https://portal.test/auth/device/token');
      expect(tokenPayload['ath'], isNotEmpty);
      expect(tokenPayload.toString(), isNot(contains('synthetic-device-code')));
      final tokenSignature = base64Url.decode(
        base64Url.normalize(tokenProof.split('.')[2]),
      );
      expect(
        _bytesBigInt(tokenSignature.sublist(32)),
        lessThanOrEqualTo(ECDomainParameters('prime256v1').n >> 1),
        reason: 'ES256 proofs must use canonical low-S signatures.',
      );

      final gatewayProof = await second.gatewayProof('synthetic-nonce');
      expect(_verifies(gatewayProof, second.publicJwk), isTrue);
      final gatewayPayload = _jwtPart(gatewayProof, 1);
      expect(gatewayPayload['htm'], 'SOCKET');
      expect(gatewayPayload['htu'], 'sanad-gateway:register_device');
      expect(gatewayPayload['nonce'], 'synthetic-nonce');
      expect(gatewayPayload['jti'], isNot(tokenPayload['jti']));
    },
  );

  test(
    'legacy P-256 identity is deleted only after verified vault write',
    () async {
      await DeviceKeyIdentity.loadOrCreate(secretStore: secrets);
      final encodedPrivate = secrets.values[DeviceKeyIdentity.privateKeyEntry]!;
      secrets.values.clear();
      final legacyFile = File('${home.path}/device_identity.json');
      await legacyFile.writeAsString(
        jsonEncode({
          'private_key': encodedPrivate,
          'public_jwk': const <String, String>{},
        }),
      );

      final migrated = await DeviceKeyIdentity.loadOrCreate(
        secretStore: secrets,
      );

      expect(migrated.publicJwk['x'], isNotEmpty);
      expect(legacyFile.existsSync(), isFalse);
      expect(secrets.values[DeviceKeyIdentity.privateKeyEntry], encodedPrivate);
    },
  );

  test(
    'failed P-256 vault verification preserves the legacy identity',
    () async {
      await DeviceKeyIdentity.loadOrCreate(secretStore: secrets);
      final encodedPrivate = secrets.values[DeviceKeyIdentity.privateKeyEntry]!;
      secrets.values.clear();
      final legacyFile = File('${home.path}/device_identity.json');
      await legacyFile.writeAsString(
        jsonEncode({
          'private_key': encodedPrivate,
          'public_jwk': const <String, String>{},
        }),
      );
      secrets.corruptWrites = true;

      await expectLater(
        DeviceKeyIdentity.loadOrCreate(secretStore: secrets),
        throwsA(isA<AgentSecretStoreUnavailable>()),
      );

      expect(legacyFile.existsSync(), isTrue);
    },
  );

  test('co-located enrollment sends non-secret hardware identity', () async {
    final client = MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload['client_id'], 'sanad_agent_colocated');
      expect(payload['device_name'], 'Sanad Agent (macOS)');
      expect(payload['platform'], 'macos');
      expect(payload['hardware_id'], 'hardware-123');
      expect(payload, isNot(contains('device_code')));
      return http.Response(
        jsonEncode({
          'transaction_id': 'colocated-transaction',
          'device_code': 'private-device-code',
          'user_code': 'ABCD-EFGH',
          'verification_uri': 'https://portal.test/device',
          'expires_in': 600,
          'interval': 5,
        }),
        200,
        headers: {
          'date': HttpDate.format(
            DateTime.now().toUtc().add(const Duration(hours: 3)),
          ),
        },
      );
    });
    final auth = AuthManager(secretStore: secrets);
    await auth.initialize();
    final authorization = DeviceAuthorizationClient(
      portalUrl: 'https://portal.test',
      authManager: auth,
      httpClient: client,
      identityLoader: () =>
          DeviceKeyIdentity.loadOrCreate(secretStore: secrets),
    );

    final enrollment = await authorization.startEnrollment(
      clientId: 'sanad_agent_colocated',
      deviceName: 'Sanad Agent (macOS)',
      platform: 'macos',
      hardwareId: 'hardware-123',
    );

    expect(enrollment.transactionId, 'colocated-transaction');
    expect(
      enrollment.serverTimeOffset,
      greaterThan(const Duration(hours: 2, minutes: 59)),
    );
    expect(
      int.parse(secrets.values[DeviceKeyIdentity.serverTimeOffsetEntry]!),
      greaterThan(const Duration(hours: 2, minutes: 59).inSeconds),
    );
    final reloadedIdentity = await DeviceKeyIdentity.loadOrCreate(
      secretStore: secrets,
    );
    final gatewayProof = await reloadedIdentity.gatewayProof('clock-skew-nonce');
    final gatewayPayload = _jwtPart(gatewayProof, 1);
    expect(
      (gatewayPayload['iat'] as int) -
          (DateTime.now().millisecondsSinceEpoch ~/ 1000),
      greaterThan(const Duration(hours: 2, minutes: 59).inSeconds),
    );
  });

  test('cancels an enrollment with a key-bound proof', () async {
    late DeviceAuthorizationEnrollment enrollment;
    final client = MockClient((request) async {
      if (request.url.path == '/auth/device/transactions') {
        return http.Response(
          jsonEncode({
            'transaction_id': 'cancelled-transaction',
            'device_code': 'private-cancel-code',
            'user_code': 'ABCD-EFGH',
            'verification_uri': 'https://portal.test/device',
            'expires_in': 600,
            'interval': 5,
          }),
          200,
        );
      }
      expect(request.url.path, '/auth/device/cancel');
      expect(request.headers['DPoP'], isNotNull);
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload, {'device_code': enrollment.deviceCode});
      final proofPayload = _jwtPart(request.headers['DPoP']!, 1);
      expect(proofPayload['htu'], 'https://portal.test/auth/device/cancel');
      expect(proofPayload.toString(), isNot(contains(enrollment.deviceCode)));
      return http.Response(jsonEncode({'status': 'cancelled'}), 200);
    });
    final auth = AuthManager(secretStore: secrets);
    await auth.initialize();
    final authorization = DeviceAuthorizationClient(
      portalUrl: 'https://portal.test',
      authManager: auth,
      httpClient: client,
      identityLoader: () =>
          DeviceKeyIdentity.loadOrCreate(secretStore: secrets),
    );
    enrollment = await authorization.startEnrollment(
      clientId: 'sanad_agent_colocated',
      deviceName: 'Sanad Agent (macOS)',
      platform: 'macos',
      hardwareId: 'hardware-123',
    );

    await authorization.cancelEnrollment(enrollment);

    expect(auth.deviceToken, isNull);
  });

  test(
    'polls with fresh proofs, honors slow_down, and survives restart',
    () async {
      const deviceCode = 'synthetic-device-code-never-display';
      var tokenPolls = 0;
      final pollIntervals = <Duration>[];
      final proofs = <String>[];
      final client = MockClient((request) async {
        if (request.url.path == '/auth/device/transactions') {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          expect(payload['client_id'], 'sanad_agent_cli');
          expect(payload['public_jwk'], isA<Map>());
          expect(payload.toString(), isNot(contains('private_key')));
          return http.Response(
            jsonEncode({
              'transaction_id': 'transaction-1',
              'device_code': deviceCode,
              'user_code': 'ABCD-EFGH',
              'verification_uri': 'https://portal.test/device',
              'expires_in': 600,
              'interval': 5,
            }),
            200,
          );
        }
        expect(request.url.path, '/auth/device/token');
        tokenPolls += 1;
        final proof = request.headers['DPoP'];
        expect(proof, isNotNull);
        proofs.add(proof!);
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['device_code'], deviceCode);
        if (tokenPolls == 1) {
          return http.Response(
            jsonEncode({
              'detail': {'error': 'authorization_pending'},
            }),
            400,
          );
        }
        if (tokenPolls == 2) {
          return http.Response(
            jsonEncode({
              'detail': {'error': 'slow_down'},
            }),
            400,
          );
        }
        return http.Response(
          jsonEncode({
            'device_credential': 'sanad_device_synthetic-credential',
            'audience': 'sanad_agent',
          }),
          200,
        );
      });
      final auth = AuthManager(secretStore: secrets);
      await auth.initialize();
      late DeviceAuthorizationChallenge displayed;
      final authorization = DeviceAuthorizationClient(
        portalUrl: 'https://portal.test',
        authManager: auth,
        httpClient: client,
        delay: (duration) async => pollIntervals.add(duration),
        identityLoader: () =>
            DeviceKeyIdentity.loadOrCreate(secretStore: secrets),
      );

      await authorization.authorize(
        deviceName: 'Test server',
        platform: 'linux',
        onChallenge: (challenge) => displayed = challenge,
      );

      expect(displayed.verificationUri, 'https://portal.test/device');
      expect(displayed.userCode, 'ABCD-EFGH');
      expect(displayed.toString(), isNot(contains(deviceCode)));
      expect(pollIntervals, const [
        Duration(seconds: 5),
        Duration(seconds: 5),
        Duration(seconds: 10),
      ]);
      expect(proofs.toSet(), hasLength(3));
      for (final proof in proofs) {
        final payload = _jwtPart(proof, 1);
        expect(payload['ath'], isNotEmpty);
        expect(payload.toString(), isNot(contains(deviceCode)));
      }
      expect(auth.deviceToken, 'sanad_device_synthetic-credential');
      expect(auth.accessToken, isNull);
      expect(auth.refreshToken, isNull);

      final authAfterRestart = AuthManager(secretStore: secrets);
      await authAfterRestart.initialize();
      expect(authAfterRestart.deviceToken, 'sanad_device_synthetic-credential');
      expect(authAfterRestart.refreshToken, isNull);
      final authFile = File('${home.path}/auth.json').readAsStringSync();
      expect(authFile, isNot(contains(deviceCode)));
    },
  );
}
