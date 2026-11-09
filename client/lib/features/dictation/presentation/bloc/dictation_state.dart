import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart' show Locale;

/// How live transcript text is surfaced in the composer.
enum DictationPreviewPolicy { live, onStop }

/// Session lifecycle of one dictation run.
enum DictationStatus { idle, preparing, listening, finalizing }

/// One catalog entry as reported by the daemon.
///
/// The daemon ships identity and facts, never sentences: [name] is the model's
/// own proper noun, [description] is the model's locale map (the one exception to
/// "no user-facing copy from the daemon"), and [badge] is a code this Client
/// localizes.
class DictationModelOption extends Equatable {
  const DictationModelOption({
    required this.id,
    this.name,
    this.labelCode,
    this.description = const {},
    this.badge,
    this.speedTier,
    this.sizeBytes,
    this.streaming = false,
    this.location = 'local',
    this.hosted = false,
    this.installed = false,
  });

  final String id;

  /// The model's real name — a proper noun, never translated.
  final String? name;

  /// Translatable identity for a daemon-owned row that is not a catalog model
  /// (for example the `stt.model_path` override). The Client localizes it.
  final String? labelCode;

  /// One-line description per locale, English being the fallback.
  final Map<String, String> description;

  /// `recommended`, `faster`, `more_accurate`, `custom`, or null for none.
  final String? badge;

  /// Relative speed, 1 (slowest) to 4 (fastest), or null when unknown.
  final int? speedTier;

  final int? sizeBytes;

  /// True when the daemon publishes text while the user speaks.
  final bool streaming;

  /// Where the model runs: `local` today, `cloud` when the catalog adds one.
  final String location;

  final bool hosted;
  final bool installed;

  bool get isStreaming => streaming;

  /// A model the daemon did not ship, so the row has no catalog name.
  bool get isCustom => badge == 'custom';

  /// The description in [locale], falling back to English.
  String descriptionFor(Locale locale) =>
      description[locale.languageCode] ?? description['en'] ?? '';

  @override
  List<Object?> get props => [
        id,
        name,
        labelCode,
        description,
        badge,
        speedTier,
        sizeBytes,
        streaming,
        location,
        hosted,
        installed,
      ];
}

/// Daemon-reported speech model state (`stt_status` + `stt_download_progress`).
class DictationModelStatus extends Equatable {
  const DictationModelStatus({
    this.selectedModelId,
    this.isReady = false,
    this.downloadProgress,
    this.installedBytes,
    this.unavailableReason,
    this.readinessReason,
    this.isPlatformSupported = true,
    this.busy = false,
    this.models = const [],
    this.installingModelId,
  });

  final String? selectedModelId;
  final bool isReady;

  /// 0..1 while a download is in flight, null otherwise.
  final double? downloadProgress;
  final int? installedBytes;

  /// Daemon-side reason the engine cannot run at all (platform, disabled).
  final String? unavailableReason;

  /// Daemon readiness reason reported independently of platform support.
  ///
  /// A device can be `supported: true` and still `ready: false` while the native
  /// runtime is missing or being prepared; discarding the reason in that case is
  /// what made the runtime states unreachable in the sheet.
  final String? readinessReason;

  /// Whether the Agent reported `supported` for dictation on this device.
  final bool isPlatformSupported;

  /// Another session holds the daemon's single dictation lease.
  final bool busy;

  /// True for any reason the user cannot clear by pressing the mic again.
  bool get hasPermanentBlocker => !isPlatformSupported;

  /// The reason the session cannot start right now, platform support included.
  String? get blockedReason => unavailableReason ?? readinessReason;

  /// Full catalog as reported by the daemon (for the model sheet).
  final List<DictationModelOption> models;

  /// Model whose install is currently running; owned here, not by the sheet,
  /// so the progress bar survives rebuilds until the daemon reports installed.
  final String? installingModelId;

  bool get isDownloading => downloadProgress != null;

  DictationModelStatus copyWith({
    String? selectedModelId,
    bool? isReady,
    double? downloadProgress,
    bool clearDownloadProgress = false,
    int? installedBytes,
    String? unavailableReason,
    String? readinessReason,
    bool clearReadinessReason = false,
    bool? isPlatformSupported,
    bool? busy,
    List<DictationModelOption>? models,
    String? installingModelId,
    bool clearInstallingModel = false,
  }) {
    return DictationModelStatus(
      selectedModelId: selectedModelId ?? this.selectedModelId,
      isReady: isReady ?? this.isReady,
      downloadProgress:
          clearDownloadProgress ? null : (downloadProgress ?? this.downloadProgress),
      installedBytes: installedBytes ?? this.installedBytes,
      unavailableReason: unavailableReason ?? this.unavailableReason,
      readinessReason: clearReadinessReason
          ? null
          : (readinessReason ?? this.readinessReason),
      isPlatformSupported: isPlatformSupported ?? this.isPlatformSupported,
      busy: busy ?? this.busy,
      models: models ?? this.models,
      installingModelId: clearInstallingModel
          ? null
          : (installingModelId ?? this.installingModelId),
    );
  }

  @override
  List<Object?> get props => [
        selectedModelId,
        isReady,
        downloadProgress,
        installedBytes,
        unavailableReason,
        readinessReason,
        isPlatformSupported,
        busy,
        models,
        installingModelId,
      ];
}

class DictationState extends Equatable {
  const DictationState({
    this.status = DictationStatus.idle,
    this.model = const DictationModelStatus(),
    this.previewPolicy = DictationPreviewPolicy.live,
    this.committedText = '',
    this.partialText = '',
    this.errorCode,
    this.sessionNeedsFirstUseSheet = false,
    this.discardText = false,
    this.level = 0,
    this.awaitingSend = false,
  });

  final DictationStatus status;
  final DictationModelStatus model;
  final DictationPreviewPolicy previewPolicy;

  /// Text the daemon finalized in this session (never mutated afterwards).
  final String committedText;

  /// Unstable tail of the current segment; empty under [onStop].
  final String partialText;

  final String? errorCode;

  /// True when the session stopped because no model is installed yet.
  final bool sessionNeedsFirstUseSheet;

  /// True when the session ended by cancel, so its dictated text must leave
  /// the composer instead of staying as user text.
  final bool discardText;

  /// Latest microphone loudness (0..1) used by the voice visualization. It is
  /// display-only: audio itself never leaves the capture callback.
  final double level;

  /// True between the moment the user asked to send mid-dictation and the
  /// moment the final transcript landed in the composer (or the wait ended).
  /// The send button renders as a stop-capable progress while it holds.
  final bool awaitingSend;

  bool get isActive =>
      status == DictationStatus.preparing ||
      status == DictationStatus.listening ||
      status == DictationStatus.finalizing;

  bool get isRecording => status == DictationStatus.listening;

  /// What the composer should show for this session right now.
  /// What the composer shows while dictating.
  ///
  /// A streaming model commits one segment per silence, and the next segment's
  /// partial arrives immediately. Concatenating the two glued the new sentence
  /// onto the old one until the segment was committed and a space appeared — the
  /// text visibly "jumped". The separator is therefore added here, from the
  /// first frame the partial is visible.
  String get visibleText {
    if (partialText.isEmpty) return committedText;
    if (committedText.isEmpty) return partialText;
    final needsSpace =
        !committedText.endsWith(' ') && !partialText.startsWith(' ');
    return needsSpace ? '$committedText $partialText' : '$committedText$partialText';
  }

  DictationState copyWith({
    DictationStatus? status,
    DictationModelStatus? model,
    DictationPreviewPolicy? previewPolicy,
    String? committedText,
    String? partialText,
    String? errorCode,
    bool clearError = false,
    bool? sessionNeedsFirstUseSheet,
    bool? discardText,
    double? level,
    bool? awaitingSend,
  }) {
    return DictationState(
      status: status ?? this.status,
      model: model ?? this.model,
      previewPolicy: previewPolicy ?? this.previewPolicy,
      committedText: committedText ?? this.committedText,
      partialText: partialText ?? this.partialText,
      errorCode: clearError ? null : (errorCode ?? this.errorCode),
      sessionNeedsFirstUseSheet:
          sessionNeedsFirstUseSheet ?? this.sessionNeedsFirstUseSheet,
      discardText: discardText ?? this.discardText,
      level: level ?? this.level,
      awaitingSend: awaitingSend ?? this.awaitingSend,
    );
  }

  @override
  List<Object?> get props => [
        status,
        model,
        previewPolicy,
        committedText,
        partialText,
        errorCode,
        sessionNeedsFirstUseSheet,
        discardText,
        // The meter only repaints when the state differs, so loudness has to be
        // part of equality or every level update is suppressed.
        level,
        awaitingSend,
      ];
}
