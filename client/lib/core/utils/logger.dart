import 'package:logging/logging.dart';
import 'package:flutter/foundation.dart';

/// Global list containing the last 1000 formatted log entries of the client in memory.
final List<String> clientLogs = [];

/// Global ValueNotifier for logs to notify Flutter UI widgets.
final ValueNotifier<List<String>> clientLogNotifier = ValueNotifier<List<String>>([]);

/// Initializes the customized, colored logger for the Flutter client.
void initClientLogger() {
  // Developer builds keep INFO diagnostics; a release build stays silent.
  // Profile builds are the on-device acceptance surface, and the device
  // inventory pending window can only be diagnosed from their logs.
  Logger.root.level = (kDebugMode || kProfileMode) ? Level.INFO : Level.OFF;

  Logger.root.onRecord.listen((record) {
    final timeStr = _formatTime(record.time);
    final levelName = record.level.name;
    final loggerName = record.loggerName;

    // Default formatting tokens
    String levelToken = '[$levelName]';
    String sourceToken = '[$loggerName]';
    String messageText = record.message;
    String resetColor = '';

    const colorEnabled = kDebugMode;
    const maxLength = 1000;

    if (colorEnabled) {
      resetColor = '\x1B[0m';

      // 1. Colorize Log Level
      if (record.level >= Level.SEVERE) {
        levelToken = '\x1B[31m[$levelName]\x1B[0m'; // Red
      } else if (record.level >= Level.WARNING) {
        levelToken = '\x1B[33m[$levelName]\x1B[0m'; // Yellow
      } else if (record.level >= Level.INFO) {
        levelToken = '\x1B[32m[$levelName]\x1B[0m'; // Green
      } else if (record.level >= Level.CONFIG) {
        levelToken = '\x1B[34m[$levelName]\x1B[0m'; // Blue
      } else {
        levelToken = '\x1B[90m[$levelName]\x1B[0m'; // Gray
      }

      // 2. Colorize Source Name (Cyan)
      sourceToken = '\x1B[36m[$loggerName]\x1B[0m';
    }

    // 3. Truncate long log messages
    if (messageText.length > maxLength) {
      messageText =
          '${messageText.substring(0, maxLength)}... $resetColor[truncated, original len: ${record.message.length}]';
    }

    // 4. Build log output line
    final logOutput = '$timeStr $levelToken $sourceToken: $messageText';
    debugPrint(logOutput);

    // Save formatted log output
    clientLogs.add(logOutput);

    // 5. Handle errors and stack traces beautifully if they are present
    if (record.error != null) {
      final errStr = colorEnabled
          ? '\x1B[1;31mError Details:\x1B[0m \x1B[31m${record.error}\x1B[0m'
          : 'Error Details: ${record.error}';
      debugPrint(errStr);
      clientLogs.add(errStr);
    }
    if (record.stackTrace != null) {
      final stStr = colorEnabled ? '\x1B[90m${record.stackTrace}\x1B[0m' : record.stackTrace.toString();
      debugPrint(stStr);
      clientLogs.add(stStr);
    }

    // Keep memory capped at 1000 items
    while (clientLogs.length > 1000) {
      clientLogs.removeAt(0);
    }

    // Notify UI listeners
    clientLogNotifier.value = List.from(clientLogs);
  });
}

/// Custom timestamp formatter: HH:mm:ss.SSS
String _formatTime(DateTime time) {
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  final second = time.second.toString().padLeft(2, '0');
  final millisecond = time.millisecond.toString().padLeft(3, '0');
  return '$hour:$minute:$second.$millisecond';
}
