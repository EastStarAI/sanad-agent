import 'dart:convert';
import 'dart:io';

import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/infrastructure/local_tools/secure_sanad_home_writer.dart';

/// Client-owned access is limited to the desktop authentication exchange.
/// MCP configuration and secrets are owned exclusively by the local daemon.
class SanadSettingsStore {
  const SanadSettingsStore({
    this.homeDirectoryPath,
    this.sanadHomePath,
    this.environment,
  });

  final String? homeDirectoryPath;
  final String? sanadHomePath;
  final Map<String, String>? environment;

  Future<Map<String, dynamic>> readAuthDocument() async {
    final file = await _secureHomeWriter().resolveFile('auth.json');
    if (!await file.exists()) return <String, dynamic>{};
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Sanad authentication data must be a JSON object.',
      );
    }
    return decoded;
  }

  Future<void> saveAuthDocument(Map<String, dynamic> authData) async {
    await _secureHomeWriter().writeText(
      'auth.json',
      const JsonEncoder.withIndent('  ').convert(authData),
    );
  }

  Future<void> deleteAuthDocument() async {
    await _secureHomeWriter().delete('auth.json');
  }

  SecureSanadHomeWriter _secureHomeWriter() {
    return SecureSanadHomeWriter(_resolveSanadHomeDirectory());
  }

  String _resolveSanadHomeDirectory() {
    final explicitSanadHome = sanadHomePath?.trim();
    if (explicitSanadHome != null && explicitSanadHome.isNotEmpty) {
      return explicitSanadHome;
    }
    if (AppConfig.sanadHome.trim().isNotEmpty) {
      return AppConfig.sanadHome.trim();
    }
    final explicitHomeDirectory = homeDirectoryPath?.trim();
    if (explicitHomeDirectory != null && explicitHomeDirectory.isNotEmpty) {
      return '$explicitHomeDirectory${Platform.pathSeparator}.sanad';
    }
    final runtimeHome = (environment ?? Platform.environment)['SANAD_HOME']?.trim();
    if (runtimeHome != null && runtimeHome.isNotEmpty) {
      return runtimeHome;
    }
    return '${_resolveHomeDirectory()}${Platform.pathSeparator}.sanad';
  }

  String _resolveHomeDirectory() {
    final explicitPath = homeDirectoryPath?.trim();
    if (explicitPath != null && explicitPath.isNotEmpty) return explicitPath;

    final processEnvironment = environment ?? Platform.environment;
    for (final key in ['HOME', 'USERPROFILE']) {
      final value = processEnvironment[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    final drive = processEnvironment['HOMEDRIVE']?.trim();
    final path = processEnvironment['HOMEPATH']?.trim();
    if (drive?.isNotEmpty == true && path?.isNotEmpty == true) {
      return '$drive$path';
    }
    throw const FileSystemException(
      'Unable to resolve the user home directory for Sanad authentication.',
    );
  }
}
