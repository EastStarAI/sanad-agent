import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';

class QueuedMessagesBox extends StatelessWidget {
  final List<CanonicalEvent> messages;
  final Color borderColor;
  final Color inputBgColor;
  final Color dimTextColor;
  final void Function(String text, {required String requestId}) onSteer;
  final void Function({required String requestId}) onDelete;
  final Set<String> pendingRequestIds;

  const QueuedMessagesBox({
    super.key,
    required this.messages,
    required this.borderColor,
    required this.inputBgColor,
    required this.dimTextColor,
    required this.onSteer,
    required this.onDelete,
    this.pendingRequestIds = const {},
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: inputBgColor.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.schedule_send_outlined,
                    size: 14,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Queued Messages (${messages.length})',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: messages.length,
                  separatorBuilder: (context, index) => Divider(
                    color: borderColor,
                    height: 1,
                  ),
                  itemBuilder: (context, index) {
                    final msg = messages[index];
                    final requestId = msg.requestId;
                    final isPending = requestId != null && pendingRequestIds.contains(requestId);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              msg.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: colorScheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (isPending)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: AppProgressIndicator(strokeWidth: 2),
                            )
                          else ...[
                            TextButton.icon(
                              onPressed: requestId == null ? null : () => onSteer(msg.text, requestId: requestId),
                              icon: const Icon(Icons.explore_outlined, size: 13),
                              label: const Text('Steer'),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                            Semantics(
                              label: 'Delete queued message',
                              child: IconButton(
                                tooltip: 'Delete queued message',
                                onPressed: requestId == null ? null : () => onDelete(requestId: requestId),
                                icon: const Icon(Icons.delete_outline, size: 16),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
