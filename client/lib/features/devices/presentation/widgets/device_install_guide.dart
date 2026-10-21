import 'package:flutter/material.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';
import 'package:sanad_release_contract/release_contract.dart';

class _InstallGuideStyle {
  const _InstallGuideStyle._();

  static const double maxWidth = 680;
  static const double cardRadius = 10;
  static const double platformIconSize = 18;
  static const double codeFontSize = 12;
  static const double lineNumberWidth = 26;
  static const double codeLineHeight = 1.55;
  static const Color editorBackground = Color(0xFF0D1117);
  static const Color editorHeader = Color(0xFF161B22);
  static const Color editorBorder = Color(0xFF30363D);
  static const Color editorText = Color(0xFFE6EDF3);
  static const Color editorMutedText = Color(0xFF8B949E);
}

class DeviceInstallGuide extends StatelessWidget {
  final String token;

  const DeviceInstallGuide({
    super.key,
    required this.token,
  });

  // The shared release contract is the single source of installer commands.
  String get _posixCommand => OfficialAgentInstaller.pairingCommand('linux', token);
  String get _windowsCommand => OfficialAgentInstaller.pairingCommand('windows', token);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: _InstallGuideStyle.maxWidth,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _InstallCommandCard(
              key: const ValueKey('posix-install-command'),
              title: 'macOS & Linux',
              subtitle: 'Terminal',
              icon: Icons.terminal_rounded,
              command: _posixCommand,
            ),
            const SizedBox(height: 14),
            _InstallCommandCard(
              key: const ValueKey('windows-install-command'),
              title: 'Windows',
              subtitle: 'PowerShell',
              icon: Icons.window_rounded,
              command: _windowsCommand,
            ),
          ],
        ),
      ),
    );
  }
}

class _InstallCommandCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final String command;

  const _InstallCommandCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.command,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '$title installation command',
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: const BoxDecoration(
          color: _InstallGuideStyle.editorBackground,
          borderRadius: BorderRadius.all(
            Radius.circular(_InstallGuideStyle.cardRadius),
          ),
          border: Border.fromBorderSide(
            BorderSide(color: _InstallGuideStyle.editorBorder),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: _InstallGuideStyle.editorHeader,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: _InstallGuideStyle.platformIconSize,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: _InstallGuideStyle.editorText,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: _InstallGuideStyle.editorMutedText,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  CopyButton(
                    text: command,
                    successMessage: '$title command copied',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(
                    width: _InstallGuideStyle.lineNumberWidth,
                    child: Text(
                      '1',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _InstallGuideStyle.editorMutedText,
                        fontFamily: 'monospace',
                        fontSize: _InstallGuideStyle.codeFontSize,
                        height: _InstallGuideStyle.codeLineHeight,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SelectableText(
                        command,
                        style: const TextStyle(
                          color: _InstallGuideStyle.editorText,
                          fontFamily: 'monospace',
                          fontSize: _InstallGuideStyle.codeFontSize,
                          height: _InstallGuideStyle.codeLineHeight,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
