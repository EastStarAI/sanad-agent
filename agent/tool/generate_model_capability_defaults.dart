import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/config.dart';
import 'package:yaml/yaml.dart';

import 'canonical_source.dart';

const modelCapabilityDefaultsSourcePath = 'model_capability_defaults.yaml';
const modelCapabilityDefaultsOutputPath =
    'lib/core/provider_thinking/generated_model_capability_defaults.dart';

const _routeClasses = {'any', 'native', 'first_party', 'google', 'nim'};
const _compatibleChatModes = {'positive_efforts'};

void main(List<String> arguments) {
  final check = arguments.contains('--check');
  final agentRoot = Directory.current.absolute;
  final source = File(p.join(agentRoot.path, modelCapabilityDefaultsSourcePath));
  if (!source.existsSync()) {
    stderr.writeln('Missing $modelCapabilityDefaultsSourcePath.');
    exitCode = 1;
    return;
  }
  final generated = renderModelCapabilityDefaults(
    canonicalLineEndings(source.readAsStringSync()),
  );
  final output = File(p.join(agentRoot.path, modelCapabilityDefaultsOutputPath));

  if (check) {
    if (!output.existsSync() ||
        !generatedSourceMatches(
          onDisk: output.readAsStringSync(),
          rendered: generated,
        )) {
      stderr.writeln(
        'Model capability defaults output is stale. Run: '
        'fvm dart run tool/generate_model_capability_defaults.dart',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln('Model capability defaults valid.');
    return;
  }

  output
    ..createSync(recursive: true)
    ..writeAsStringSync(generated);
  stdout.writeln(
    'Generated ${p.relative(output.path, from: agentRoot.path)}.',
  );
}

/// Validates [yamlText] and renders the generated Dart source.
///
/// Every `thinking_control` record is validated through the same
/// [ThinkingControlOverride.parse] the user `config.yaml` uses, so shipped
/// defaults can never carry a record a user could not declare.
String renderModelCapabilityDefaults(String yamlText) {
  final decoded = loadYaml(yamlText);
  if (decoded is! YamlMap || decoded['schema_version'] != 1) {
    throw const FormatException('Unsupported model capability defaults.');
  }
  final models = decoded['model_capabilities'];
  if (models is! YamlMap || models.isEmpty) {
    throw const FormatException('model_capabilities must not be empty.');
  }

  final rows = <String, Map<String, Object?>>{};
  for (final entry in models.entries) {
    final id = entry.key;
    final raw = entry.value;
    if (id is! String || id.trim() != id || id.isEmpty) {
      throw FormatException('Invalid model id: $id');
    }
    if (raw is! YamlMap) {
      throw FormatException('Entry $id must be a map.');
    }
    const allowedKeys = {
      'source',
      'note',
      'aliases',
      'routes',
      'compatible_chat',
      'thinking_control',
    };
    for (final key in raw.keys) {
      if (!allowedKeys.contains(key)) {
        throw FormatException('Entry $id has unknown key "$key".');
      }
    }
    final source = raw['source'];
    if (source is! String || source.trim().isEmpty) {
      throw FormatException('Entry $id requires a documentation source.');
    }
    final routes = raw['routes'];
    if (routes != null && !_routeClasses.contains(routes)) {
      throw FormatException('Entry $id has an unknown routes class: $routes');
    }
    final compatibleChat = raw['compatible_chat'];
    if (compatibleChat != null && !_compatibleChatModes.contains(compatibleChat)) {
      throw FormatException('Entry $id has an unknown compatible_chat mode.');
    }
    final control = _plain(raw['thinking_control']);
    if (control is! Map<String, Object?>) {
      throw FormatException('Entry $id requires a thinking_control map.');
    }
    // Same validation as the user configuration schema.
    final parsed = ThinkingControlOverride.parse(
      Map<String, dynamic>.from(control),
      context: 'model_capability_defaults.$id.thinking_control',
    );
    final row = <String, Object?>{
      'source': source.trim(),
      'routes': routes ?? _defaultRoutes(parsed.wire),
      'compatible_chat': ?compatibleChat,
      'thinking_control': control,
    };
    final ids = [id];
    final aliases = raw['aliases'];
    if (aliases != null) {
      if (aliases is! YamlList) {
        throw FormatException('Entry $id aliases must be a list.');
      }
      for (final alias in aliases) {
        if (alias is! String || alias.trim() != alias || alias.isEmpty) {
          throw FormatException('Entry $id has an invalid alias.');
        }
        ids.add(alias);
      }
    }
    for (final key in ids) {
      if (rows.containsKey(key)) {
        throw FormatException('Duplicate model id or alias: $key');
      }
      rows[key] = row;
    }
  }

  final revision = sha256
      .convert(utf8.encode(jsonEncode(rows)))
      .toString();
  final out = StringBuffer()
    ..writeln('// This file is generated. Do not edit manually.')
    ..writeln('// Source: agent/$modelCapabilityDefaultsSourcePath')
    ..writeln(
      '// Regenerate: fvm dart run tool/generate_model_capability_defaults.dart',
    )
    ..writeln()
    ..writeln("const modelCapabilityDefaultsRevision = '$revision';")
    ..writeln()
    ..writeln('/// Shipped thinking-capability defaults keyed by exact model id.')
    ..writeln(
      'const modelCapabilityDefaults = <String, ShippedModelCapabilityDefault>{',
    );
  for (final entry in rows.entries) {
    final row = entry.value;
    out
      ..writeln('  ${jsonEncode(entry.key)}: ShippedModelCapabilityDefault(')
      ..writeln('    source: ${jsonEncode(row['source'])},')
      ..writeln('    routes: ${jsonEncode(row['routes'])},');
    if (row['compatible_chat'] != null) {
      out.writeln('    compatibleChat: ${jsonEncode(row['compatible_chat'])},');
    }
    out
      ..writeln('    thinkingControl: ${_literal(row['thinking_control'])},')
      ..writeln('  ),');
  }
  out
    ..writeln('};')
    ..writeln()
    ..writeln('class ShippedModelCapabilityDefault {')
    ..writeln(
      '  const ShippedModelCapabilityDefault({required this.source, required this.routes, this.compatibleChat, required this.thinkingControl});',
    )
    ..writeln('  final String source;')
    ..writeln('  final String routes;')
    ..writeln('  final String? compatibleChat;')
    ..writeln('  final Map<String, Object?> thinkingControl;')
    ..writeln('}');
  return out.toString();
}

String _defaultRoutes(String? wire) => switch (wire) {
  'native_toggle_effort' => 'native',
  'google_thinking' => 'google',
  'nim_kimi_thinking' || 'nim_qwen_thinking' => 'nim',
  _ => 'any',
};

Object? _plain(Object? value) {
  if (value is YamlMap) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _plain(entry.value),
    };
  }
  if (value is YamlList) return value.map(_plain).toList();
  return value;
}

String _literal(Object? value) {
  if (value is Map) {
    final parts = value.entries
        .map((entry) => '${jsonEncode(entry.key)}: ${_literal(entry.value)}')
        .join(', ');
    return '<String, Object?>{$parts}';
  }
  return jsonEncode(value);
}
