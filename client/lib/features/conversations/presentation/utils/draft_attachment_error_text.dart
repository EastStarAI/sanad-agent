import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Localized copy for a [DraftAttachmentError], stating the limit that was
/// actually enforced.
abstract final class DraftAttachmentErrorText {
  static String describe(AppLocalizations l10n, DraftAttachmentError error) => switch (error.kind) {
    DraftAttachmentErrorKind.unsupported => l10n.attachmentErrorUnsupported,
    DraftAttachmentErrorKind.tooLarge => l10n.attachmentErrorTooLarge(formatLimit(error.limit)),
    DraftAttachmentErrorKind.tooMany => l10n.attachmentErrorTooMany(error.limit),
    DraftAttachmentErrorKind.totalTooLarge => l10n.attachmentErrorTotalTooLarge(formatLimit(error.limit)),
    DraftAttachmentErrorKind.sendFailed => l10n.attachmentErrorSendFailed,
    DraftAttachmentErrorKind.readFailed => l10n.attachmentErrorReadFailed,
  };

  /// Formats a byte limit with binary units: whole MiB or KiB when exact,
  /// otherwise one decimal of MiB/KiB, and plain bytes below one KiB.
  static String formatLimit(int bytes) {
    const kib = 1024;
    const mib = 1024 * 1024;
    String unit(double value, String suffix) {
      final text = value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
      return '$text $suffix';
    }

    if (bytes >= mib) return unit(bytes / mib, 'MiB');
    if (bytes >= kib) return unit(bytes / kib, 'KiB');
    return '$bytes B';
  }
}
