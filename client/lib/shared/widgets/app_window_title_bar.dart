import 'package:flutter/material.dart';
import 'package:sanad_client/infrastructure/platform/window_manager_service.dart';
import 'package:window_manager/window_manager.dart';

class AppWindowTitleBar extends StatelessWidget {
  const AppWindowTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      child: Stack(
        children: [
          // Drag area for the whole bar
          const Positioned.fill(
            child: DragToMoveArea(
              child: SizedBox.expand(),
            ),
          ),
          // Content
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(width: 12),
              // App Icon
              Image.asset(
                'assets/app-logo.png',
                width: 18,
                height: 18,
              ),
              const SizedBox(width: 10),
              // App Name
              Text(
                'Sanad',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              // Window Buttons
              WindowCaptionButton.minimize(
                brightness: Theme.of(context).brightness,
                onPressed: () => windowManager.minimize(),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: WindowManagerService.maximizedOrFullScreenListenable,
                builder: (context, isMaximizedOrFullScreen, _) {
                  if (isMaximizedOrFullScreen) {
                    return WindowCaptionButton.unmaximize(
                      brightness: Theme.of(context).brightness,
                      onPressed: WindowManagerService.toggleMaximized,
                    );
                  }
                  return WindowCaptionButton.maximize(
                    brightness: Theme.of(context).brightness,
                    onPressed: WindowManagerService.toggleMaximized,
                  );
                },
              ),
              WindowCaptionButton.close(
                brightness: Theme.of(context).brightness,
                onPressed: () => windowManager.close(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
