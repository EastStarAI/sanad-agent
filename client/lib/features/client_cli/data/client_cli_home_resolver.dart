import 'dart:io';
import 'package:path/path.dart' as p;

class ClientCliHomeResolver {
  const ClientCliHomeResolver();

  /// Resolves the Sanad Home directory according to the locked contract:
  /// 1. Explicit `--home` parameter
  /// 2. `SANAD_HOME` environment variable
  /// 3. Default user home (`$HOME/.sanad` or `%USERPROFILE%\.sanad`)
  String resolveSanadHome({
    String? explicitHome,
    Map<String, String>? environment,
  }) {
    final explicit = explicitHome?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return p.normalize(p.absolute(explicit));
    }

    final env = environment ?? Platform.environment;
    final envHome = env['SANAD_HOME']?.trim();
    if (envHome != null && envHome.isNotEmpty) {
      return p.normalize(p.absolute(envHome));
    }

    final userHome = env['HOME']?.trim().isNotEmpty == true
        ? env['HOME']!.trim()
        : env['USERPROFILE']?.trim().isNotEmpty == true
        ? env['USERPROFILE']!.trim()
        : null;

    if (userHome != null && userHome.isNotEmpty) {
      return p.normalize(p.absolute(p.join(userHome, '.sanad')));
    }

    return p.normalize(p.absolute('.sanad'));
  }
}
