import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';

Future<void> main(List<String> args) async {
  try {
    getIt<Config>();
  } catch (_) {
    setupDI();
  }

  final config = getIt<Config>();
  final authManager = getIt<AuthManager>();
  await authManager.initialize();

  // Check for --status argument
  if (args.contains('--status')) {
    await runStatus();
    return;
  }

  // Check for --token / -t argument
  String? tokenArg;
  for (var i = 0; i < args.length; i++) {
    if ((args[i] == '--token' || args[i] == '-t') && i + 1 < args.length) {
      tokenArg = args[i + 1];
      break;
    }
  }

  final portalOnly = args.contains('--portal');
  if (portalOnly && tokenArg != null) {
    stderr.writeln('Choose either --portal or --token, not both.');
    exit(64);
  }

  if (tokenArg != null && tokenArg.isNotEmpty) {
    print('Preparing device pairing...');
    await authManager.prepareDevicePairing(tokenArg);
    await _notifyRunningDaemon(config);
    print('✓ Device pairing is ready. Start the Sanad service to connect.');
    return;
  }

  print('');
  print('┌─────────────────────────────────────────────────────────┐');
  print('│             ⚕ Sanad Agent Login Wizard                   │');
  print('├─────────────────────────────────────────────────────────┤');
  print('│  Authenticate your Headless Server / Device             │');
  print('└─────────────────────────────────────────────────────────┘');
  print('');

  String? response;
  if (!portalOnly) {
    stdout.write('Do you want to use a Device Token from the UI? [y/N]: ');
    response = stdin.readLineSync()?.trim().toLowerCase();
  }

  if (response == 'y' || response == 'yes') {
    stdout.write('Paste your Device Token here: ');
    final pastedToken = stdin.readLineSync()?.trim();
    if (pastedToken == null || pastedToken.isEmpty) {
      print('❌ Invalid token. Aborting.');
      exit(1);
    }
    print('Preparing device pairing...');
    await authManager.prepareDevicePairing(pastedToken);
    await _notifyRunningDaemon(config);
    print('✓ Device pairing is ready. Start the Sanad service to connect.');
    return;
  }

  // Plan 23: sanad login must use sanad-portal only. It sends platform + capabilities to /auth/start,
  // never naming a provider or a flow. The portal decides whether a user_code is required (CLI/headless).
  final portalUrl = config.portalUrl;
  print('Starting portal auth session via: $portalUrl');

  try {
    final startUrl = Uri.parse('$portalUrl/auth/start');
    final startResponse = await http.post(
      startUrl,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'platform': 'cli',
        'capabilities': const ['headless', 'system_browser'],
      }),
    );

    if (startResponse.statusCode != 200) {
      print(
        '❌ Failed to start login session: HTTP ${startResponse.statusCode}',
      );
      print(startResponse.body);
      exit(1);
    }

    final startData = jsonDecode(startResponse.body) as Map<String, dynamic>;
    final authSessionId = startData['auth_session_id'] as String;
    final pollingToken = startData['polling_token'] as String;
    final authUrl = startData['auth_url'] as String;
    final userCode = startData['user_code'] as String?;
    final intervalSeconds = (startData['interval'] as num?)?.toInt() ?? 2;
    final expiresIn = (startData['expires_in'] as num?)?.toInt() ?? 300;

    print('\nPlease open the following link in your web browser:');
    print('─────────────────────────────────────────────────────────');
    print(authUrl);
    print('─────────────────────────────────────────────────────────');
    if (userCode != null && userCode.isNotEmpty) {
      print('Then enter this code when prompted on the portal page:');
      print('─────────────────────────────────────────────────────────');
      print(userCode);
      print('─────────────────────────────────────────────────────────\n');
    } else {
      print('Sign-in is handled by the portal page directly.\n');
    }
    print('Waiting for authentication to complete (Ctrl+C to abort)...');

    // Polling Loop
    var attempts = 0;
    final maxAttempts = (expiresIn / intervalSeconds).ceil();

    while (attempts < maxAttempts) {
      await Future.delayed(Duration(seconds: intervalSeconds));
      attempts++;

      final statusResponse = await http.post(
        Uri.parse('$portalUrl/auth/status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'auth_session_id': authSessionId,
          'polling_token': pollingToken,
        }),
      );
      if (statusResponse.statusCode != 200) {
        continue;
      }

      final statusData =
          jsonDecode(statusResponse.body) as Map<String, dynamic>;
      final statusStr = statusData['status'] as String;

      if (statusStr == 'completed') {
        final accessToken = statusData['access_token'] as String;
        final refreshToken = statusData['refresh_token'] as String?;

        print('\nSaving tokens...');
        await authManager.saveUserTokens(accessToken, refreshToken ?? '');
        await _notifyRunningDaemon(config);
        print('✓ Login successful! Session tokens stored in auth.json.');
        return;
      } else if (statusStr == 'expired') {
        print('\n❌ Login session has expired. Please run "sanad login" again.');
        exit(1);
      } else if (statusStr == 'cancelled') {
        print('\n❌ Login cancelled.');
        exit(1);
      }
    }

    print('\n❌ Login timed out. Please try again.');
    exit(1);
  } catch (e) {
    print('❌ Connection error: $e');
    exit(1);
  }
}

Future<void> runLogout() async {
  try {
    getIt<Config>();
  } catch (_) {
    setupDI();
  }

  final config = getIt<Config>();
  final authManager = getIt<AuthManager>();
  await authManager.initialize();

  print('Logging out...');
  await authManager.logout();
  await _notifyRunningDaemon(config);
  print('✓ Successfully logged out. Session tokens and device tokens removed.');
}

Future<void> _notifyRunningDaemon(Config config) async {
  try {
    final credential = await LocalGatewayCredentials.loadOrCreate();
    final base = Uri.parse(config.localGatewayUrl);
    await http
        .post(
          base.replace(path: '/authentication-exchange', query: null),
          headers: {LocalGatewayCredentials.headerName: credential.value},
        )
        .timeout(const Duration(milliseconds: 750));
  } catch (_) {
    // The daemon may be stopped. It will load auth.json on its next startup.
  }
}

Future<void> runStatus() async {
  try {
    getIt<Config>();
  } catch (_) {
    setupDI();
  }

  final authManager = getIt<AuthManager>();
  await authManager.initialize();

  print('=== ⚕ Sanad Agent Status ===');
  print('Hardware ID: ${authManager.hardwareId}');
  if (authManager.accessToken != null) {
    print('Status: Authenticated (Web Login / User Token)');
  } else if (authManager.deviceToken != null) {
    print('Status: Authenticated (Device Token)');
  } else if (authManager.hasPendingDevicePairing) {
    print('Status: Device Pairing Pending');
  } else {
    print('Status: Not Authenticated (Offline / Local-Only Mode)');
  }
}
