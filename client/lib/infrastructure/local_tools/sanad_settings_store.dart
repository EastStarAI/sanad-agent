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
  });

  final String? homeDirectoryPath;
  final String? sanadHomePath;

  Future<Map<String, dynamic>> readAuthDocument() async {
    final file = await _secureHomeWriter().resolveFile('auth.json');
    if (!await file.exists()) return <String, dynamic>{};
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Sanad authentication data must be a JSON object.');
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
    return '${_resolveHomeDirectory()}${Platform.pathSeparator}.sanad';
  }

  String _resolveHomeDirectory() {
    final explicitPath = homeDirectoryPath?.trim();
    if (explicitPath != null && explicitPath.isNotEmpty) return explicitPath;

    final environment = Platform.environment;
    for (final key in ['HOME', 'USERPROFILE']) {
      final value = environment[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    final drive = environment['HOMEDRIVE']?.trim();
    final path = environment['HOMEPATH']?.trim();
    if (drive?.isNotEmpty == true && path?.isNotEmpty == true) {
      return '$drive$path';
    }
    throw const FileSystemException(
      'Unable to resolve the user home directory for Sanad authentication.',
    );
  }
}
