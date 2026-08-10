import 'dart:async';
import 'dart:io';

import 'package:sanad_auth_lock/sanad_auth_lock.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('Expected: <home> <ready-file> <release-file>');
    exitCode = 64;
    return;
  }
  final home = args[0];
  final ready = File(args[1]);
  final release = File(args[2]);

  await NativeAuthFileLock(home).runExclusive(() async {
    await ready.writeAsString('ready', flush: true);
    while (!await release.exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}
