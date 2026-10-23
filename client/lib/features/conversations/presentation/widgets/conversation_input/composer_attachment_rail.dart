import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/utils/draft_attachment_error_text.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/l10n/app_localizations_en.dart';
import 'package:sanad_client/shared/widgets/file_extension_icon.dart';

import 'composer_helpers.dart';

class ComposerAttachmentRail extends StatelessWidget {
  const ComposerAttachmentRail({
    required this.attachments,
    required this.error,
    required this.borderColor,
    required this.dimTextColor,
  });

  final List<DraftAttachment> attachments;
  final DraftAttachmentError? error;
  final Color borderColor;
  final Color dimTextColor;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty && error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (attachments.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final attachment in attachments)
                  Container(
                    key: ValueKey('draft_attachment_${attachment.id}'),
                    width: 180,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: borderColor),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: attachment.isImage
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.memory(
                                    attachment.bytes,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const Icon(Symbols.image, size: 20),
                                  ),
                                )
                              : Center(child: FileExtensionIcon(fileName: attachment.name, size: 20)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                attachment.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '${formatAttachmentBytes(attachment.sizeBytes)} · ${attachment.status.name}',
                                style: TextStyle(fontSize: 11, color: dimTextColor),
                              ),
                            ],
                          ),
                        ),
                        if (attachment.status == DraftAttachmentStatus.failed)
                          IconButton(
                            key: ValueKey('retry_attachment_${attachment.id}'),
                            tooltip: 'Retry attachment',
                            onPressed: () => context.read<ConversationInputCubit>().retryDraftAttachment(attachment.id),
                            icon: const Icon(Symbols.refresh, size: 18),
                            visualDensity: VisualDensity.compact,
                          ),
                        IconButton(
                          key: ValueKey('remove_attachment_${attachment.id}'),
                          tooltip: 'Remove attachment',
                          onPressed: () => context.read<ConversationInputCubit>().removeDraftAttachment(attachment.id),
                          icon: const Icon(Symbols.close, size: 18),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          if (error case final error?) ...[
            const SizedBox(height: 6),
            ComposerAttachmentErrorLine(
              error: error,
              onDismiss: () => context.read<ConversationInputCubit>().clearAttachmentError(),
            ),
          ],
        ],
      ),
    );
  }
}

/// Transient attachment rejection with an explicit dismiss control.
class ComposerAttachmentErrorLine extends StatelessWidget {
  const ComposerAttachmentErrorLine({required this.error, required this.onDismiss});

  final DraftAttachmentError error;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context) ?? AppLocalizationsEn();
    final color = Theme.of(context).colorScheme.error;
    return Row(
      children: [
        Expanded(
          child: Text(
            DraftAttachmentErrorText.describe(l10n, error),
            key: const Key('attachment_error'),
            style: TextStyle(color: color, fontSize: 12),
          ),
        ),
        IconButton(
          key: const Key('attachment_error_dismiss'),
          tooltip: l10n.attachmentErrorDismiss,
          onPressed: onDismiss,
          icon: Icon(Symbols.close, size: 16, color: color),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

