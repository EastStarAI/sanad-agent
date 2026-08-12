import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:pointycastle/export.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../sanad_home/sanad_home_bootstrap.dart';
import 'agent_secret_store.dart';
import 'auth_manager.dart';

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String defaultAgentDeviceName(String platform) {
  final osName = switch (platform.toLowerCase()) {
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    _ => 'Unknown OS',
  };
  return 'Sanad Agent ($osName)';
}

Uint8List _bigIntBytes(BigInt value, {int length = 32}) {
  final result = Uint8List(length);
  var remaining = value;
  for (var index = length - 1; index >= 0; index--) {
    result[index] = (remaining & BigInt.from(0xff)).toInt();
    remaining >>= 8;
  }
  if (remaining != BigInt.zero) {
    throw StateError('P-256 integer exceeds the fixed coordinate size.');
  }
  return result;
}

BigInt _bytesBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

FortunaRandom _secureRandom() {
  final seed = Uint8List.fromList(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );
  return FortunaRandom()..seed(KeyParameter(seed));
}

class DeviceKeyIdentity {
  DeviceKeyIdentity._(this._keyPair, this.publicJwk, this.thumbprint);

  static const _legacyFileName = 'device_identity.json';
  static const privateKeyEntry = 'device_private_key';
  static final _domain = ECDomainParameters('prime256v1');
  final ECPrivateKey _keyPair;
  final Map<String, String> publicJwk;
  final String thumbprint;

  static Future<DeviceKeyIdentity> loadOrCreate({
    AgentSecretStore? secretStore,
  }) async {
    final store = secretStore ?? createAgentSecretStore();
    final boundary = SanadHomeBootstrap.identity();
    var encodedPrivateKey = await store.read(privateKeyEntry);

    if (encodedPrivateKey == null && boundary.fileExists(_legacyFileName)) {
      final data =
          jsonDecode(utf8.decode(boundary.readSecretBytes(_legacyFileName)))
              as Map<String, dynamic>;
      encodedPrivateKey = data['private_key'] as String;
      await store.write(privateKeyEntry, encodedPrivateKey);
      if (await store.read(privateKeyEntry) != encodedPrivateKey) {
        throw const AgentSecretStoreUnavailable(
          'P-256 identity migration verification failed.',
        );
      }
      await boundary.deleteFile(_legacyFileName);
    }

    if (encodedPrivateKey == null) {
      final generator = ECKeyGenerator()
        ..init(
          ParametersWithRandom(
            ECKeyGeneratorParameters(_domain),
            _secureRandom(),
          ),
        );
      final generated = generator.generateKeyPair();
      encodedPrivateKey = _b64(_bigIntBytes(generated.privateKey.d!));
      await store.write(privateKeyEntry, encodedPrivateKey);
      if (await store.read(privateKeyEntry) != encodedPrivateKey) {
        throw const AgentSecretStoreUnavailable(
          'P-256 identity write verification failed.',
        );
      }
    }

    final privateValue = _bytesBigInt(
      base64Url.decode(base64Url.normalize(encodedPrivateKey)),
    );
    final privateKey = ECPrivateKey(privateValue, _domain);
    final publicPoint = (_domain.G * privateValue)!;
    final publicJwk = <String, String>{
      'kty': 'EC',
      'crv': 'P-256',
      'x': _b64(_bigIntBytes(publicPoint.x!.toBigInteger()!)),
      'y': _b64(_bigIntBytes(publicPoint.y!.toBigInteger()!)),
    };
    return DeviceKeyIdentity._(privateKey, publicJwk, _thumbprint(publicJwk));
  }

  static String _thumbprint(Map<String, String> jwk) {
    final canonical = jsonEncode({
      'crv': 'P-256',
      'kty': 'EC',
      'x': jwk['x'],
      'y': jwk['y'],
    });
    return _b64(hashes.sha256.convert(utf8.encode(canonical)).bytes);
  }

  Future<String> signProof(Map<String, dynamic> payload) async {
    final header = <String, dynamic>{
      'alg': 'ES256',
      'typ': 'dpop+jwt',
      'jwk': publicJwk,
    };
    final encodedHeader = _b64(utf8.encode(jsonEncode(header)));
    final encodedPayload = _b64(utf8.encode(jsonEncode(payload)));
    final signingInput = '$encodedHeader.$encodedPayload';
    final signer = Signer('SHA-256/ECDSA')
      ..init(
        true,
        ParametersWithRandom(
          PrivateKeyParameter<ECPrivateKey>(_keyPair),
          _secureRandom(),
        ),
      );
    final signature =
        signer.generateSignature(Uint8List.fromList(utf8.encode(signingInput)))
            as ECSignature;
    final joseSignature = Uint8List.fromList([
      ..._bigIntBytes(signature.r),
      ..._bigIntBytes(signature.s),
    ]);
    return '$signingInput.${_b64(joseSignature)}';
  }

  Future<String> deviceTokenProof(Uri endpointUri, String deviceCode) {
    return signProof({
      'htm': 'POST',
      'htu': endpointUri.toString(),
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'jti': const Uuid().v4(),
      'ath': _b64(hashes.sha256.convert(utf8.encode(deviceCode)).bytes),
    });
  }

  Future<String> gatewayProof(String nonce) {
    return signProof({
      'htm': 'SOCKET',
      'htu': 'sanad-gateway:register_device',
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'jti': const Uuid().v4(),
      'nonce': nonce,
    });
  }
}

class DeviceAuthorizationChallenge {
  final String verificationUri;
  final String userCode;
  final String shortenedThumbprint;

  const DeviceAuthorizationChallenge({
    required this.verificationUri,
    required this.userCode,
    required this.shortenedThumbprint,
  });
}

/// Private Agent-owned half of one Device Authorization transaction.
///
/// [transactionId] is safe to disclose as correlation identity. [deviceCode]
/// is bearer-like delivery authority and must never leave the Agent process.
class DeviceAuthorizationEnrollment {
  const DeviceAuthorizationEnrollment({
    required this.transactionId,
    required this.deviceCode,
    required this.expiresIn,
    required this.interval,
    required this.identity,
    required this.challenge,
  });

  final String transactionId;
  final String deviceCode;
  final int expiresIn;
  final int interval;
  final DeviceKeyIdentity identity;
  final DeviceAuthorizationChallenge challenge;
}

class DeviceAuthorizationClient {
  DeviceAuthorizationClient({
    required this.portalUrl,
    required this.authManager,
    http.Client? httpClient,
    Future<void> Function(Duration duration)? delay,
    Future<DeviceKeyIdentity> Function()? identityLoader,
  }) : _httpClient = httpClient ?? http.Client(),
       _delay = delay ?? Future<void>.delayed,
       _identityLoader = identityLoader ?? DeviceKeyIdentity.loadOrCreate;

  static const _slowDownIncrementSeconds = 5;
  static const _maximumPollIntervalSeconds = 30;

  final String portalUrl;
  final AuthManager authManager;
  final http.Client _httpClient;
  final Future<void> Function(Duration duration) _delay;
  final Future<DeviceKeyIdentity> Function() _identityLoader;

  Future<DeviceAuthorizationChallenge> authorize({
    required String deviceName,
    required String platform,
    required void Function(DeviceAuthorizationChallenge challenge) onChallenge,
  }) async {
    final enrollment = await startEnrollment(
      clientId: 'sanad_agent_cli',
      deviceName: deviceName,
      platform: platform,
    );
    onChallenge(enrollment.challenge);
    await redeemEnrollment(enrollment);
    return enrollment.challenge;
  }

  Future<DeviceAuthorizationEnrollment> startEnrollment({
    required String clientId,
    required String deviceName,
    required String platform,
    String? hardwareId,
  }) async {
    final identity = await _identityLoader();
    final startUri = Uri.parse('$portalUrl/auth/device/transactions');
    final startResponse = await _httpClient.post(
      startUri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'client_id': clientId,
        'public_jwk': identity.publicJwk,
        'device_name': deviceName,
        'platform': platform,
        'hardware_id': ?hardwareId,
      }),
    );
    if (startResponse.statusCode != 200) {
      throw StateError('Could not start Agent authorization.');
    }
    final started = jsonDecode(startResponse.body) as Map<String, dynamic>;
    return DeviceAuthorizationEnrollment(
      transactionId: started['transaction_id'] as String,
      deviceCode: started['device_code'] as String,
      expiresIn: (started['expires_in'] as num).toInt(),
      interval: (started['interval'] as num).toInt(),
      identity: identity,
      challenge: DeviceAuthorizationChallenge(
        verificationUri: started['verification_uri'] as String,
        userCode: started['user_code'] as String,
        shortenedThumbprint: identity.thumbprint.substring(0, 12),
      ),
    );
  }

  Future<void> cancelEnrollment(
    DeviceAuthorizationEnrollment enrollment,
  ) async {
    final cancelUri = Uri.parse('$portalUrl/auth/device/cancel');
    final proof = await enrollment.identity.deviceTokenProof(
      cancelUri,
      enrollment.deviceCode,
    );
    final response = await _httpClient.post(
      cancelUri,
      headers: {'Content-Type': 'application/json', 'DPoP': proof},
      body: jsonEncode({'device_code': enrollment.deviceCode}),
    );
    if (response.statusCode != 200) {
      throw StateError('Could not cancel Agent authorization.');
    }
  }

  Future<void> redeemEnrollment(
    DeviceAuthorizationEnrollment enrollment, {
    bool Function()? isActive,
  }) async {
    bool active() => isActive?.call() ?? true;
    var interval = enrollment.interval;
    final tokenUri = Uri.parse('$portalUrl/auth/device/token');
    final deadline = DateTime.now().add(
      Duration(seconds: enrollment.expiresIn),
    );
    while (DateTime.now().isBefore(deadline)) {
      if (!active()) return;
      await _delay(Duration(seconds: interval));
      if (!active()) return;
      final proof = await enrollment.identity.deviceTokenProof(
        tokenUri,
        enrollment.deviceCode,
      );
      final response = await _httpClient.post(
        tokenUri,
        headers: {'Content-Type': 'application/json', 'DPoP': proof},
        body: jsonEncode({
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'device_code': enrollment.deviceCode,
        }),
      );
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (!active()) return;
      if (response.statusCode == 200) {
        final credential = data['device_credential'] as String;
        if (!active()) return;
        await authManager.saveDeviceToken(credential);
        return;
      }
      final detail = data['detail'];
      final error = detail is Map ? detail['error']?.toString() : null;
      if (error == 'authorization_pending') continue;
      if (error == 'slow_down') {
        interval = min(
          interval + _slowDownIncrementSeconds,
          _maximumPollIntervalSeconds,
        );
        continue;
      }
      if (error == 'access_denied' || error == 'expired_token') {
        throw StateError('Agent authorization $error.');
      }
      if (response.statusCode >= 500) continue;
      throw StateError('Agent authorization failed.');
    }
    throw StateError('Agent authorization expired.');
  }
}
