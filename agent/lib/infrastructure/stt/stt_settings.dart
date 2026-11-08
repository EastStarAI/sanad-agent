/// `config.yaml` `stt:` section parsing for local dictation.
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;

import 'package:yaml/yaml.dart';

import 'stt_catalog.dart';
import 'stt_types.dart';

/// Whether the recognizer should use the GPU when the config does not say.
///
/// Apple Silicon keeps Metal, and Linux/Windows keep their existing policy, so
/// this only carves out Intel macOS: the x64 whisper.cpp baseline has no usable
/// Metal path there, so defaulting GPUs on would add load cost and then fail at
/// decode. An explicit `stt.use_gpu` still wins in either direction.
bool defaultSttUseGpu() => defaultSttUseGpuFor(Abi.current());

/// [defaultSttUseGpu] for an explicit ABI, so the carve-out is testable from any
/// host instead of only on the machine it protects.
bool defaultSttUseGpuFor(Abi abi) => abi != Abi.macosX64;

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

/// File the daemon owns for the dictation toggle exposed in Device settings.
///
/// It is deliberately separate from `config.yaml`: that file belongs to the
/// owner and is hand-edited, so a runtime toggle must never rewrite it (no YAML
/// round trip can preserve an owner's comments and ordering). Precedence is
/// therefore explicit `config.yaml` > this file > defaults, and the settings
/// projection reports `managed_externally` when `config.yaml` names the key.
const String kSttRuntimePreferencesFile = 'runtime-preferences.json';

String sttRuntimePreferencesPath(String sanadHome) =>
    '$sanadHome/models/stt/$kSttRuntimePreferencesFile';

/// The subset of dictation settings the daemon may persist for the UI.
///
/// Model selection is *not* stored here: `selection.json` already owns it and
/// the `select` command writes it, so a second selection authority would let the
/// sheet and the settings page disagree.
class SttRuntimePreferences {
  const SttRuntimePreferences({this.enabled});

  final bool? enabled;

  static SttRuntimePreferences read({required String sanadHome}) {
    final file = File(sttRuntimePreferencesPath(sanadHome));
    if (!file.existsSync()) return const SttRuntimePreferences();
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return const SttRuntimePreferences();
      final enabled = decoded['enabled'];
      return SttRuntimePreferences(enabled: enabled is bool ? enabled : null);
    } on Object {
      // A corrupt preference file falls back to the config/default value.
      return const SttRuntimePreferences();
    }
  }

  /// Writes the toggle, keeping every other persisted preference intact.
  static Future<void> writeEnabled({
    required String sanadHome,
    required bool enabled,
  }) async {
    final path = sttRuntimePreferencesPath(sanadHome);
    await Directory(File(path).parent.path).create(recursive: true);
    final existing = <String, dynamic>{};
    final file = File(path);
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map) existing.addAll(Map<String, dynamic>.from(decoded));
      } on Object {
        // Overwrite an unreadable file rather than fail the user's change.
      }
    }
    existing['enabled'] = enabled;
    await file.writeAsString(jsonEncode(existing));
  }
}

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
    this.configKeys = const <String>{},
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

  /// Keys `config.yaml` named explicitly.
  ///
  /// The owner's file is authoritative: a key listed here cannot be changed
  /// from the Client, and the settings projection says so instead of silently
  /// writing a value that the next reload would discard.
  final Set<String> configKeys;

  bool get keepsModelWarm => modelIdleMinutes != 0;

  /// True when the owner pinned `stt.enabled`, so the toggle is read-only.
  bool get enabledManagedByConfig => configKeys.contains('enabled');

  String get effectiveModelId =>
      modelId.isNotEmpty ? modelId : defaultSttEntry.id;

  /// Reads the `stt:` section of `<sanadHome>/config.yaml`, then layers the
  /// daemon-persisted runtime preferences under it.
  ///
  /// Unknown keys are ignored so a newer config never breaks an older daemon.
  /// Wrong types fail loudly with the offending key, because silently running
  /// with the wrong language or thread count is worse than refusing to start.
  static SttSettings load({required String sanadHome}) {
    final preferences = SttRuntimePreferences.read(sanadHome: sanadHome);
    final base = const SttSettings();
    final file = File('$sanadHome/config.yaml');
    if (!file.existsSync()) {
      return SttSettings(
        enabled: preferences.enabled ?? base.enabled,
      );
    }
    final Object? root;
    try {
      root = loadYaml(file.readAsStringSync());
    } on YamlException catch (error) {
      throw SttException('config_invalid', 'stt config is not valid YAML: $error');
    }
    if (root is! YamlMap) {
      return SttSettings(enabled: preferences.enabled ?? base.enabled);
    }
    final section = root['stt'];
    if (section == null) {
      return SttSettings(enabled: preferences.enabled ?? base.enabled);
    }
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
      enabled: readBool('enabled', preferences.enabled ?? base.enabled),
      modelId: modelId,
      modelPath: readString('model_path'),
      language: language,
      threads: threads,
      useGpu: readBool('use_gpu', defaultSttUseGpu()),
      modelIdleMinutes: readInt('model_idle_minutes', 5),
      configKeys: {
        for (final key in section.keys) key.toString(),
      },
    );
  }
}
