import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:toastification/toastification.dart';
import 'package:sanad_client/utils/app_platform.dart';

class ToastUtils {
  static final _logger = Logger('ToastUtils');
  static ValueChanged<String>? debugOnShowError;
  static ValueChanged<String>? debugOnShowInfo;

  /// Minimum time user-visible feedback remains readable before auto-close.
  static const defaultDuration = Duration(seconds: 5);

  static void showError(BuildContext context, String message) {
    debugOnShowError?.call(message);
    _logger.warning('Showing user-visible error toast');
    _show(
      context,
      message,
      type: ToastificationType.error,
      icon: Icons.error_outline,
      color: Theme.of(context).colorScheme.error,
    );
  }

  static void showSuccess(BuildContext context, String message) => _show(
    context,
    message,
    type: ToastificationType.success,
    icon: Icons.check_circle_outline,
    color: Theme.of(context).colorScheme.primary,
  );

  /// Neutral, non-failure notice (for example, an operation still running).
  static void showInfo(BuildContext context, String message) {
    debugOnShowInfo?.call(message);
    _show(
      context,
      message,
      type: ToastificationType.info,
      icon: Icons.info_outline,
      color: Theme.of(context).colorScheme.primary,
    );
  }

  static void _show(
    BuildContext context,
    String message, {
    required ToastificationType type,
    required IconData icon,
    required Color color,
  }) {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    toastification.show(
      context: context,
      type: type,
      style: ToastificationStyle.flat,
      autoCloseDuration: defaultDuration,
      title: Text(message),
      alignment: AppPlatform.isMobile
          ? Alignment.topCenter
          : (isRtl ? Alignment.topLeft : Alignment.topRight),
      direction: isRtl ? TextDirection.rtl : TextDirection.ltr,
      animationDuration: const Duration(milliseconds: 300),
      icon: Icon(icon, color: color),
      showIcon: true,
      primaryColor: color,
      backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.35),
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      borderSide: BorderSide(
        color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.30),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      borderRadius: BorderRadius.circular(12),
      showProgressBar: true,
      closeButton: const ToastCloseButton(),
      closeOnClick: false,
      pauseOnHover: true,
      dragToClose: true,
      applyBlurEffect: true,
    );
  }
}
