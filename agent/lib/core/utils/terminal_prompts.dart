import 'dart:async';
import 'dart:io';

int selectInteractive(String title, List<String> options) {
  if (!stdin.hasTerminal) {
    print(title);
    for (int i = 0; i < options.length; i++) {
      print('  ${i + 1}. ${options[i]}');
    }
    while (true) {
      stdout.write('Select [1-${options.length}] (default: 1): ');
      final input = stdin.readLineSync()?.trim();
      if (input == null || input.isEmpty) {
        return 0;
      }
      final parsed = int.tryParse(input);
      if (parsed != null && parsed >= 1 && parsed <= options.length) {
        return parsed - 1;
      }
      print('Invalid choice.');
    }
  }

  print(title);

  var selectedIndex = 0;
  final originalLineMode = stdin.lineMode;
  final originalEchoMode = stdin.echoMode;

  // Ctrl+C must restore the terminal before exit; on Windows the process is
  // otherwise killed before the finally block below runs.
  final sigintSubscription = ProcessSignal.sigint.watch().listen((_) {
    try {
      stdin.lineMode = originalLineMode;
      stdin.echoMode = originalEchoMode;
      stdout.write('\x1b[?25h');
    } on Object {
      // The host terminal may not expose mutable modes.
    }
    exit(130);
  });

  try {
    stdin.lineMode = false;
    stdin.echoMode = false;
    stdout.write('\x1b[?25l');

    void render() {
      stdout.write('\r');
      for (int i = 0; i < options.length; i++) {
        stdout.write('\x1b[F\x1b[K');
      }

      for (int i = 0; i < options.length; i++) {
        if (i == selectedIndex) {
          print('\x1b[36m➔ \x1b[1m${options[i]}\x1b[0m');
        } else {
          print('  ${options[i]}');
        }
      }
    }

    for (int i = 0; i < options.length; i++) {
      print('');
    }

    render();

    while (true) {
      final code = stdin.readByteSync();

      if (code == 13 || code == 10) {
        break;
      }

      if (code == 27) {
        final next1 = stdin.readByteSync();
        final next2 = stdin.readByteSync();

        if (next1 == 91) {
          if (next2 == 65) {
            if (selectedIndex > 0) {
              selectedIndex--;
              render();
            }
          } else if (next2 == 66) {
            if (selectedIndex < options.length - 1) {
              selectedIndex++;
              render();
            }
          }
        }
      }
    }
  } finally {
    unawaited(sigintSubscription.cancel());
    stdin.lineMode = originalLineMode;
    stdin.echoMode = originalEchoMode;
    stdout.write('\x1b[?25h');
  }

  return selectedIndex;
}
