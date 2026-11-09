// Downloads one catalog model into a Sanad home and reports progress.
//
// Usage:
//   fvm dart run tool/stt_install.dart <sanad_home> [model_id]
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/stt_catalog.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_settings.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: stt_install.dart <sanad_home> [model_id]');
    exit(64);
  }
  final home = args[0];
  final entry = args.length > 1 ? sttEntryById(args[1]) : defaultSttEntry;
  if (entry == null) {
    stderr.writeln('unknown model id: ${args[1]}');
    exit(65);
  }

  final store = SttModelStore(sanadHome: home);
  var lastTenth = -1;
  var started = DateTime.now();
  stdout.writeln('installing ${entry.id} into $home');

  await store.install(
    entry,
    onProgress: (id, received, total) {
      if (total <= 0) return;
      final tenth = (received * 10 ~/ total);
      if (tenth == lastTenth) return;
      lastTenth = tenth;
      final elapsed = DateTime.now().difference(started);
      final seconds = elapsed.inMilliseconds / 1000;
      final mbps = seconds == 0 ? 0.0 : received / 1e6 / seconds;
      stdout.writeln(
        '  ${(received / 1e6).toStringAsFixed(0)}/'
        '${(total / 1e6).toStringAsFixed(0)} MB '
        '(${mbps.toStringAsFixed(1)} MB/s)',
      );
    },
  );

  final resolved = store.resolve(const SttSettings(), selectedModelId: entry.id);
  stdout.writeln('installed: ${resolved != null}');
  if (resolved != null) {
    stdout.writeln('encoder: ${resolved.encoder}');
    stdout.writeln('vad: ${resolved.vad}');
  }
  started = DateTime.now();
}
