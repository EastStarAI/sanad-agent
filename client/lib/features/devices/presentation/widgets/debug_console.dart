import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:sanad_client/core/presentation/state/app_log_store.dart';
import 'package:sanad_client/core/theme/app_typography.dart';

class DebugConsole extends StatefulWidget {
  final VoidCallback onClose;
  const DebugConsole({super.key, required this.onClose});

  @override
  State<DebugConsole> createState() => _DebugConsoleState();
}

class _DebugConsoleState extends State<DebugConsole> {
  final ScrollController _scrollController = ScrollController();
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      if (_scrollController.offset > 100 && !_showScrollToBottom) {
        setState(() => _showScrollToBottom = true);
      } else if (_scrollController.offset <= 100 && _showScrollToBottom) {
        setState(() => _showScrollToBottom = false);
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      unawaited(
        _scrollController.animateTo(
          0, // 0 is bottom
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final logStore = context.read<AppLogStore>();

    return ValueListenableBuilder<List<String>>(
      valueListenable: logStore.logNotifier,
      builder: (context, logs, _) {
        return Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Debug Console',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Row(
                    children: [
                      if (_showScrollToBottom)
                        IconButton(
                          icon: Icon(Icons.arrow_downward, color: Theme.of(context).colorScheme.primary, size: 16),
                          onPressed: _scrollToBottom,
                          tooltip: 'Scroll to Bottom',
                        ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          Icons.close,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 16,
                        ),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: SelectionArea(
                child: ListView.builder(
                  controller: _scrollController,
                  reverse: true, // Stick to bottom naturally
                  itemCount: logs.length,
                  padding: const EdgeInsets.all(8),
                  itemBuilder: (context, index) {
                    if (index >= logs.length) return const SizedBox.shrink();
                    final log = logs[logs.length - 1 - index];

                    return Text(
                      log,
                      style: AppTypography.mono(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 11,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
