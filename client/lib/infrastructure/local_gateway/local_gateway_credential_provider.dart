import 'package:sanad_client/core/config/app_config.dart';
import 'package:universal_io/io.dart';

class LocalGatewayCredentialException implements Exception {
  const LocalGatewayCredentialException(this.code);

  final String code;

  @override
  String toString() => 'LocalGatewayCredentialException($code)';
}

/// Reads the local gateway credential from the active Sanad Home.
///
/// The value is returned only as an HTTP header and must never be copied into
/// URLs, process arguments, environment variables, preferences, or logs.
class LocalGatewayCredentialProvider {
  const LocalGatewayCredentialProvider({this.sanadHomePath});

  static const headerName = 'x-sanad-local-token';
  static const credentialFileName = '.local_token';

  final String? sanadHomePath;

  Future<String> read() async {
    final home = _resolveSanadHome();
    final file = File(
      '$home${Platform.pathSeparator}$credentialFileName',
    );
    try {
      final homeType = await FileSystemEntity.type(home, followLinks: false);
      if (homeType != FileSystemEntityType.directory) {
        throw const LocalGatewayCredentialException('unsafe_home');
      }
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        throw const LocalGatewayCredentialException('credential_unavailable');
      }
      if (!Platform.isWindows && ((await file.stat()).mode & 0x1ff) != 0x180) {
        throw const LocalGatewayCredentialException('credential_permissions');
      }
      final value = (await file.readAsString()).trim();
      if (value.isEmpty) {
        throw const LocalGatewayCredentialException('credential_unavailable');
      }
      return value;
    } on LocalGatewayCredentialException {
      rethrow;
    } on Object {
      throw const LocalGatewayCredentialException('credential_unavailable');
    }
  }

  Future<Map<String, String>> headers() async => {
    headerName: await read(),
  };

  String _resolveSanadHome() {
    final explicit = sanadHomePath?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;

    final configured = AppConfig.sanadHome.trim();
    if (configured.isNotEmpty) return configured;

    final environment = Platform.environment;
    final userHome = environment['HOME']?.trim().isNotEmpty == true
        ? environment['HOME']!.trim()
        : environment['USERPROFILE']?.trim().isNotEmpty == true
        ? environment['USERPROFILE']!.trim()
        : null;
    if (userHome == null) {
      throw const LocalGatewayCredentialException('home_unavailable');
    }
    return '$userHome${Platform.pathSeparator}.sanad';
  }
}
