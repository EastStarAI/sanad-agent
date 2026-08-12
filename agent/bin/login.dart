import 'dart:io';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_authentication_exchange_notifier.dart';

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

  final portalUrl = config.portalUrl;
  final platform = Platform.isLinux
      ? 'linux'
      : Platform.isMacOS
      ? 'macos'
      : Platform.isWindows
      ? 'windows'
      : 'unknown';
  try {
    final authorization = DeviceAuthorizationClient(
      portalUrl: portalUrl,
      authManager: authManager,
    );
    await authorization.authorize(
      deviceName: Platform.localHostname,
      platform: platform,
      onChallenge: (challenge) {
        print('\nOpen this fixed Portal address on any trusted device:');
        print(challenge.verificationUri);
        print('\nEnter this code: ${challenge.userCode}');
        print('Verify Agent key: ${challenge.shortenedThumbprint}');
        print('\nWaiting for explicit approval (Ctrl+C to abort)...');
      },
    );
    await _notifyRunningDaemon(config);
    print('✓ Agent authorized with a key-bound device credential.');
  } catch (error) {
    print('❌ Agent authorization failed: ${error.runtimeType}');
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
  final outcome = await LocalAuthenticationExchangeNotifier().notify(
    config.localGatewayUrl,
  );
  if (outcome == LocalAuthenticationExchangeOutcome.daemonRejected) {
    stderr.writeln(
      'Authentication state was saved, but the running Sanad service did not '
      'reload it. Run: sanad service restart',
    );
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
