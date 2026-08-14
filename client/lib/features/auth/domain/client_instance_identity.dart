import 'package:package_info_plus/package_info_plus.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class ClientDisplayMetadata {
  const ClientDisplayMetadata({
    required this.clientKind,
    required this.platformFamily,
    this.osFamily,
    this.browserFamily,
    this.appVersion,
  });

  final String clientKind;
  final String platformFamily;
  final String? osFamily;
  final String? browserFamily;
  final String? appVersion;

  Map<String, dynamic> toJson() => {
    'client_kind': clientKind,
    'platform_family': platformFamily,
    if (osFamily != null) 'os_family': osFamily,
    if (browserFamily != null) 'browser_family': browserFamily,
    if (appVersion != null) 'app_version': appVersion,
  };
}

class ClientInstanceIdentity {
  static const _preferenceKey = 'client_instance_id_v1';
  static final _uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  ClientInstanceIdentity({
    required SharedPreferences preferences,
    String Function()? uuidFactory,
    Future<PackageInfo> Function()? packageInfoLoader,
    String Function()? platformName,
    bool Function()? isWeb,
    bool Function()? isDesktop,
    bool Function()? isMobile,
  }) : _preferences = preferences,
       _uuidFactory = uuidFactory ?? const Uuid().v4,
       _packageInfoLoader = packageInfoLoader ?? PackageInfo.fromPlatform,
       _platformName = platformName ?? (() => AppPlatform.name),
       _isWeb = isWeb ?? (() => AppPlatform.isWeb),
       _isDesktop = isDesktop ?? (() => AppPlatform.isDesktop),
       _isMobile = isMobile ?? (() => AppPlatform.isMobile);

  final SharedPreferences _preferences;
  final String Function() _uuidFactory;
  final Future<PackageInfo> Function() _packageInfoLoader;
  final String Function() _platformName;
  final bool Function() _isWeb;
  final bool Function() _isDesktop;
  final bool Function() _isMobile;

  Future<String> load() async {
    final existing = _preferences.getString(_preferenceKey)?.trim();
    if (existing != null && _uuidV4.hasMatch(existing)) return existing;
    final generated = _uuidFactory();
    if (!_uuidV4.hasMatch(generated)) {
      throw StateError(
        'Client instance identity generator returned an invalid UUID.',
      );
    }
    await _preferences.setString(_preferenceKey, generated);
    return generated;
  }

  Future<ClientDisplayMetadata> metadata() async {
    final platform = _normalizedPlatform(_platformName());
    String? version;
    try {
      final raw = (await _packageInfoLoader()).version.trim();
      if (_safeToken(raw)) version = raw;
    } catch (_) {
      // Missing package metadata is an allowed privacy-preserving fallback.
    }
    return ClientDisplayMetadata(
      clientKind: _isWeb()
          ? 'web'
          : _isDesktop()
          ? 'desktop'
          : _isMobile()
          ? 'mobile'
          : 'unknown',
      platformFamily: platform,
      osFamily: platform == 'web' || platform == 'unknown' ? null : platform,
      browserFamily: null,
      appVersion: version,
    );
  }

  static String _normalizedPlatform(String value) {
    const allowed = {'web', 'macos', 'windows', 'linux', 'ios', 'android'};
    final normalized = value.trim().toLowerCase();
    return allowed.contains(normalized) ? normalized : 'unknown';
  }

  static bool _safeToken(String value) =>
      value.isNotEmpty &&
      value.length <= 32 &&
      RegExp(r'^[A-Za-z0-9._+\-]+$').hasMatch(value);
}
