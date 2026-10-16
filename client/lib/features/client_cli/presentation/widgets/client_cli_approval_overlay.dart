import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../../data/client_cli_approval_coordinator.dart';

class ClientCliApprovalOverlay extends StatelessWidget {
  final Widget child;

  const ClientCliApprovalOverlay({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final coordinator = context.watch<ClientCliApprovalCoordinator>();

    return StreamBuilder<ClientCliApprovalRequest?>(
      stream: coordinator.requestStream,
      initialData: coordinator.currentRequest,
      builder: (context, snapshot) {
        final request = snapshot.data;
        return Stack(
          children: [
            child,
            if (request != null) _ApprovalDialog(request: request),
          ],
        );
      },
    );
  }
}

class _ApprovalDialog extends StatefulWidget {
  final ClientCliApprovalRequest request;

  const _ApprovalDialog({required this.request});

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      final character = event.character;
      final logicalKey = event.logicalKey;

      if (character == '1' ||
          character == '١' ||
          logicalKey == LogicalKeyboardKey.digit1 ||
          logicalKey == LogicalKeyboardKey.numpad1) {
        _resolve(ClientCliApprovalDecision.allowOnce);
        return KeyEventResult.handled;
      }
      if (character == '2' ||
          character == '٢' ||
          logicalKey == LogicalKeyboardKey.digit2 ||
          logicalKey == LogicalKeyboardKey.numpad2) {
        _resolve(ClientCliApprovalDecision.allowSession);
        return KeyEventResult.handled;
      }
      if (character == '3' ||
          character == '٣' ||
          logicalKey == LogicalKeyboardKey.digit3 ||
          logicalKey == LogicalKeyboardKey.numpad3 ||
          logicalKey == LogicalKeyboardKey.escape) {
        _resolve(ClientCliApprovalDecision.deny);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _resolve(ClientCliApprovalDecision decision) {
    final coordinator = context.read<ClientCliApprovalCoordinator>();
    coordinator.resolveCurrent(decision);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: Material(
        color: Colors.black54,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.shield_outlined, size: 20, color: colorScheme.tertiary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          l10n.clientCliApprovalTitle,
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText.rich(
                          TextSpan(
                            style: TextStyle(fontSize: 13, color: colorScheme.onSurface),
                            children: [
                              const TextSpan(
                                text: 'Device: ',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              TextSpan(text: '${widget.request.deviceName} (${widget.request.deviceId})'),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        SelectableText.rich(
                          TextSpan(
                            style: TextStyle(fontSize: 13, color: colorScheme.onSurface),
                            children: [
                              const TextSpan(
                                text: 'Command: ',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              TextSpan(
                                text: widget.request.commandPreview,
                                style: const TextStyle(fontFamily: 'monospace'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  _buildAction(
                    context,
                    key: const Key('client_cli_allow_once_btn'),
                    label: '1  ${l10n.clientCliAllowOnce}',
                    primary: true,
                    onTap: () => _resolve(ClientCliApprovalDecision.allowOnce),
                  ),
                  const SizedBox(height: 8),
                  _buildAction(
                    context,
                    key: const Key('client_cli_allow_session_btn'),
                    label: '2  ${l10n.clientCliAllowSession}',
                    primary: false,
                    onTap: () => _resolve(ClientCliApprovalDecision.allowSession),
                  ),
                  const SizedBox(height: 8),
                  _buildAction(
                    context,
                    key: const Key('client_cli_deny_btn'),
                    label: '3  ${l10n.clientCliDeny}',
                    primary: false,
                    isDeny: true,
                    onTap: () => _resolve(ClientCliApprovalDecision.deny),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAction(
    BuildContext context, {
    required Key key,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
    bool isDeny = false,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: primary
              ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: primary
                ? colorScheme.primary.withValues(alpha: 0.35)
                : isDeny
                    ? colorScheme.error.withValues(alpha: 0.25)
                    : colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
            color: isDeny ? colorScheme.error : colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
