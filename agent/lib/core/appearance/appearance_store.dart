import 'dart:convert';

import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';

class AppearanceStore {
  const AppearanceStore({this.homeBoundary});

  final SanadHomeBootstrap? homeBoundary;

  SanadHomeBootstrap get _boundary => homeBoundary ?? SanadHomeBootstrap.state();

  static const String appearanceFileName = 'appearance.json';

  static const Map<String, dynamic> defaultAppearance = {
    'theme_style': 'dark',
    'primary_color': 'blue',
    'font_family': 'system',
    'font_size': 'normal',
    'background_option': 'defaultTheme',
  };

  Future<Map<String, dynamic>> readAppearance() async {
    try {
      if (!_boundary.fileExists(appearanceFileName)) {
        return Map<String, dynamic>.from(defaultAppearance);
      }
      final bytes = _boundary.readSecretBytes(appearanceFileName);
      final text = utf8.decode(bytes).trim();
      if (text.isEmpty) {
        return Map<String, dynamic>.from(defaultAppearance);
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        return Map<String, dynamic>.from(defaultAppearance);
      }
      final map = Map<String, dynamic>.from(decoded);
      return {
        'theme_style': (map['theme_style'] ?? map['themeStyle'] ?? defaultAppearance['theme_style']).toString(),
        'primary_color': (map['primary_color'] ?? map['primaryColor'] ?? defaultAppearance['primary_color']).toString(),
        'font_family': (map['font_family'] ?? map['fontFamily'] ?? defaultAppearance['font_family']).toString(),
        'font_size': (map['font_size'] ?? map['fontSize'] ?? defaultAppearance['font_size']).toString(),
        'background_option': (map['background_option'] ?? map['backgroundOption'] ?? defaultAppearance['background_option']).toString(),
      };
    } catch (_) {
      return Map<String, dynamic>.from(defaultAppearance);
    }
  }

  Future<Map<String, dynamic>> saveAppearance(Map<String, dynamic> appearance) async {
    final current = await readAppearance();
    final updated = <String, dynamic>{
      'theme_style': (appearance['theme_style'] ?? appearance['themeStyle'] ?? current['theme_style']).toString(),
      'primary_color': (appearance['primary_color'] ?? appearance['primaryColor'] ?? current['primary_color']).toString(),
      'font_family': (appearance['font_family'] ?? appearance['fontFamily'] ?? current['font_family']).toString(),
      'font_size': (appearance['font_size'] ?? appearance['fontSize'] ?? current['font_size']).toString(),
      'background_option': (appearance['background_option'] ?? appearance['backgroundOption'] ?? current['background_option']).toString(),
    };
    final jsonText = const JsonEncoder.withIndent('  ').convert(updated);
    await _boundary.writeConfigText(appearanceFileName, jsonText);
    return updated;
  }
}
