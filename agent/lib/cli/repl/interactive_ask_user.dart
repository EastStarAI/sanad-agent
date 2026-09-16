import '../models/cli_events.dart';
import 'repl_line_reader.dart';

/// Handles interactive clarification prompts from `system_ask_user`.
class InteractiveAskUserHandler {
  /// Prompts the user interactively to answer questions in [event] using [lineReader],
  /// and returns the resolved answer string.
  static Future<String> prompt({
    required CliPermissionRequestEvent event,
    required ReplLineReader lineReader,
    required StringSink output,
    bool ansi = false,
  }) async {
    final questions = event.questions;

    if (questions.isEmpty) {
      // Fallback: extract question string from raw payload if present
      final payload = event.raw['payload'] is Map
          ? event.raw['payload'] as Map
          : {};
      final qText =
          (payload['question'] ?? payload['text'] ?? 'Clarification requested:')
              .toString();

      output.writeln();
      output.writeln(
        ansi
            ? '\x1b[1;33m❓ [Clarification Requested]\x1b[0m'
            : '❓ [Clarification Requested]',
      );
      output.writeln('   $qText');

      final answer = await lineReader.readLine(
        prompt: ansi ? '\x1b[1;36mAnswer > \x1b[0m' : 'Answer > ',
      );
      return answer?.trim() ?? '';
    }

    final answers = <String>[];

    for (int i = 0; i < questions.length; i++) {
      final q = questions[i];
      final qText = (q['question'] ?? 'Question ${i + 1}').toString();
      final rawOptions = q['options'];
      final options = <String>[];

      if (rawOptions is List) {
        for (final opt in rawOptions) {
          if (opt is Map) {
            options.add(
              (opt['label'] ?? opt['text'] ?? opt['value'] ?? opt.toString())
                  .toString(),
            );
          } else {
            options.add(opt.toString());
          }
        }
      }

      output.writeln();
      output.writeln(
        ansi
            ? '\x1b[1;33m❓ [Clarification Requested]\x1b[0m'
            : '❓ [Clarification Requested]',
      );
      output.writeln('   $qText');

      if (options.isNotEmpty) {
        for (var idx = 0; idx < options.length; idx++) {
          output.writeln('   [${idx + 1}] ${options[idx]}');
        }
        output.writeln('   [w] Custom write-in answer');

        final promptOptions = [...options, 'Custom write-in answer'];
        final shortcutMap = <String, int>{
          'w': options.length,
          'write': options.length,
        };
        for (var idx = 0; idx < options.length; idx++) {
          shortcutMap['${idx + 1}'] = idx;
        }

        final choiceIndex = await lineReader.selectOption(
          title: ansi
              ? '\x1b[1;36mSelect an answer:\x1b[0m'
              : 'Select an answer:',
          options: promptOptions,
          defaultIndex: 0,
          shortcutMap: shortcutMap,
        );

        if (choiceIndex == -1) {
          answers.add(lineReader.lastCustomInput?.trim() ?? '');
        } else if (choiceIndex == options.length) {
          final customAnswer = await lineReader.readLine(
            prompt: ansi
                ? '\x1b[1;36mCustom Answer > \x1b[0m'
                : 'Custom Answer > ',
          );
          answers.add(customAnswer?.trim() ?? '');
        } else {
          answers.add(options[choiceIndex]);
        }
      } else {
        // Free-form input
        final answer = await lineReader.readLine(
          prompt: ansi ? '\x1b[1;36mAnswer > \x1b[0m' : 'Answer > ',
        );
        answers.add(answer?.trim() ?? '');
      }
    }

    return answers.join('\n');
  }
}
