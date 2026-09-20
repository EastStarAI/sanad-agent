import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';

/// History-only fork marker styled like the context-compaction timeline event.
class ConversationForkEventTile extends StatefulWidget {
  final CanonicalEvent event;

  const ConversationForkEventTile({super.key, required this.event});

  @override
  State<ConversationForkEventTile> createState() => _ConversationForkEventTileState();
}

class _ConversationForkEventTileState extends State<ConversationForkEventTile> {
  final GlobalKey<TooltipState> _tooltipKey = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sequence = widget.event.metadata?['fork_sequence'];
    final detail = [
      if (sequence != null) 'Fork $sequence',
      'This conversation continues independently.',
    ].join('\n');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(child: Divider(color: colorScheme.outlineVariant)),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 0.75,
              ),
              child: Semantics(
                label: 'Conversation forked',
                button: true,
                child: Tooltip(
                  key: _tooltipKey,
                  message: detail,
                  child: InkWell(
                    key: const ValueKey('conversation-fork-event'),
                    onTap: () => _tooltipKey.currentState?.ensureTooltipVisible(),
                    onFocusChange: (focused) {
                      if (focused) {
                        _tooltipKey.currentState?.ensureTooltipVisible();
                      } else {
                        Tooltip.dismissAllToolTips();
                      }
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.account_tree_outlined,
                              size: 16,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                widget.event.text,
                                maxLines: 2,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: Divider(color: colorScheme.outlineVariant)),
          ],
        ),
      ),
    );
  }
}
