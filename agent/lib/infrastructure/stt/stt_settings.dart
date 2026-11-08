/// `config.yaml` `stt:` section parsing for local dictation.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:yaml/yaml.dart';

import 'stt_catalog.dart';
import 'stt_types.dart';

/// Thread count when the config does not name one.
///
/// Measured on an Apple silicon laptop (4 performance + 6 efficiency cores,
/// `egy-whisper-turbo-ggml-q8`, same 6 s sample) — decode time by thread count:
///
/// | threads | 4 | 5 | 6 | 8 |
/// |---|---|---|---|---|
/// | Metal  | 1607 ms | 1060 ms | 1069 ms | 1049 ms |
///
/// The curve plateaus at five, so wide machines get 6 and small ones keep the
/// whisper.cpp baseline (`min(4, cores)`) instead of oversubscribing.
int sttThreadsFor(int cores) {
  if (cores <= 0) return 4;
  if (cores >= 8) return 6;
  return math.min(4, cores);
}

int get defaultSttThreads => sttThreadsFor(Platform.numberOfProcessors);

/// Effective dictation settings for this daemon.
class SttSettings {
  const SttSettings({
    this.enabled = true,
    this.modelId = '',
    this.modelPath,
    this.language = 'ar',
    this.threads = 4,
    this.useGpu = true,
    this.modelIdleMinutes = 5,
  });

  final bool enabled;

  /// Catalog id. Empty means "the catalog default".
  final String modelId;

  /// Absolute path to an already-installed sherpa ONNX model directory. When
  /// set it wins over [modelId]: no download and no catalog checksum.
  final String? modelPath;

  final String language;
  final int threads;

  /// Metal acceleration for the whisper path. Off forces the CPU backend,
  /// which is also the automatic fallback when the model fails to open on the
  /// GPU (see `whispercpp_isolate.dart`).
  final bool useGpu;

  /// Minutes the recogniser stays in memory after the last session.
  ///
  /// `0` frees it as soon as a session ends, a negative value keeps it for the
  /// daemon's lifetime. The default matches the reference app (5 minutes) and
  /// exists so a burst of dictation does not pay the model load every time.
  final int modelIdleMinutes;

  bool get keepsModelWarm => modelIdleMinutes != 0;

  String get effectiveModelId =>
      modelId.isNotEmpty ? modelId : defaultSttEntry.id;

  /// Reads the `stt:` section of `<sanadHome>/config.yaml`.
  ///
  /// Unknown keys are ignored so a newer config never breaks an older daemon.
  /// Wrong types fail loudly with the offending key, because silently running
  /// with the wrong language or thread count is worse than refusing to start.
  static SttSettings load({required String sanadHome}) {
    final file = File('$sanadHome/config.yaml');
    if (!file.existsSync()) return const SttSettings();
    final Object? root;
    try {
      root = loadYaml(file.readAsStringSync());
    } on YamlException catch (error) {
      throw SttException('config_invalid', 'stt config is not valid YAML: $error');
    }
    if (root is! YamlMap) return const SttSettings();
    final section = root['stt'];
    if (section == null) return const SttSettings();
    if (section is! YamlMap) {
      throw const SttException('config_invalid', 'stt must be a mapping');
    }

    bool readBool(String key, bool fallback) {
      final value = section[key];
      if (value == null) return fallback;
      if (value is bool) return value;
      throw SttException('config_invalid', 'stt.$key must be a boolean');
    }

    String? readString(String key) {
      final value = section[key];
      if (value == null) return null;
      if (value is String) return value;
      throw SttException('config_invalid', 'stt.$key must be a string');
    }

    int readInt(String key, int fallback) {
      final value = section[key];
      if (value == null) return fallback;
      if (value is int) return value;
      throw SttException('config_invalid', 'stt.$key must be an integer');
    }

    final modelId = readString('model_id') ?? '';
    if (modelId.isNotEmpty && sttEntryById(modelId) == null) {
      throw SttException(
        'config_invalid',
        'stt.model_id "$modelId" is not in the catalog '
            '(${kSttCatalog.map((e) => e.id).join(', ')})',
      );
    }
    final threads = readInt('threads', defaultSttThreads);
    if (threads < 1 || threads > 16) {
      throw const SttException('config_invalid', 'stt.threads must be 1..16');
    }
    final language = (readString('language') ?? 'ar').trim();
    if (language.isEmpty || language.length > 8) {
      throw const SttException('config_invalid', 'stt.language is invalid');
    }

    return SttSettings(
      enabled: readBool('enabled', true),
      modelId: modelId,
      modelPath: readString('model_path'),
      language: language,
      threads: threads,
      useGpu: readBool('use_gpu', true),
      modelIdleMinutes: readInt('model_idle_minutes', 5),
    );
  }
}
