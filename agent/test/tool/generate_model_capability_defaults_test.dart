/// Freshness and validation for the shipped thinking-capability defaults
/// (`model_capability_defaults.yaml` -> generated Dart), mirroring the
/// `tool/generate_bundled_skills.dart --check` gate that CI also runs.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:sanad_agent/core/provider_thinking/generated_model_capability_defaults.dart';
import 'package:test/test.dart';

import '../../tool/canonical_source.dart';
import '../../tool/generate_model_capability_defaults.dart';

/// The agent package root, resolved independently of the process working
/// directory (other suites change it while files run concurrently).
Uri _agentRoot() => Isolate.resolvePackageUriSync(
  Uri.parse('package:sanad_agent/'),
)!.resolve('../');

void main() {
  test('generated defaults are up to date with the YAML source', () {
    final root = _agentRoot();
    final source = File.fromUri(
      root.resolve(modelCapabilityDefaultsSourcePath),
    ).readAsStringSync();
    final generated = File.fromUri(
      root.resolve(modelCapabilityDefaultsOutputPath),
    ).readAsStringSync();
    expect(
      renderModelCapabilityDefaults(source),
      generated,
      reason:
          'Run: fvm dart run tool/generate_model_capability_defaults.dart',
    );
  });

  test('every shipped record carries a documentation source', () {
    expect(modelCapabilityDefaults, isNotEmpty);
    for (final entry in modelCapabilityDefaults.entries) {
      expect(entry.value.source.trim(), isNotEmpty, reason: entry.key);
      expect(
        const {'any', 'native', 'first_party', 'google', 'nim'},
        contains(entry.value.routes),
        reason: entry.key,
      );
    }
  });

  test('records are validated with the user config schema', () {
    expect(
      () => renderModelCapabilityDefaults('''
schema_version: 1
model_capabilities:
  bad-model:
    source: "https://example.invalid/doc"
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        low: high
'''),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => renderModelCapabilityDefaults('''
schema_version: 1
model_capabilities:
  no-source:
    thinking_control:
      status: unsupported
'''),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => renderModelCapabilityDefaults('''
schema_version: 1
model_capabilities:
  a:
    source: "https://example.invalid/doc"
    aliases: ["b"]
    thinking_control:
      status: unsupported
  b:
    source: "https://example.invalid/doc"
    thinking_control:
      status: unsupported
'''),
      throwsA(isA<FormatException>()),
      reason: 'an alias may not collide with another exact id',
    );
  });

  test('a CRLF checkout is not reported as stale output', () {
    final root = _agentRoot();
    final generated = File.fromUri(
      root.resolve(modelCapabilityDefaultsOutputPath),
    ).readAsStringSync();
    expect(
      generatedSourceMatches(
        onDisk: generated.replaceAll('\n', '\r\n'),
        rendered: generated,
      ),
      isTrue,
      reason:
          'Git for Windows checks text files out with CRLF, so a line-ending '
          'difference is not staleness.',
    );
    expect(
      generatedSourceMatches(onDisk: '$generated//', rendered: generated),
      isFalse,
      reason: 'real content drift must still fail the check',
    );
  });

  test('the rendered output does not depend on source line endings', () {
    final source = File.fromUri(
      _agentRoot().resolve(modelCapabilityDefaultsSourcePath),
    ).readAsStringSync();
    final lf = canonicalLineEndings(source);
    expect(
      renderModelCapabilityDefaults(lf.replaceAll('\n', '\r\n')),
      renderModelCapabilityDefaults(lf),
    );
  });
}
