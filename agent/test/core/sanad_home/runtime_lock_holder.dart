import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/runtime_ownership.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';

Future<void> main(List<String> arguments) async {
  final home = arguments.single;
  setSanadHomeOverride(home);
  setSanadStateHomeOverride(home);
  await SanadHomeBootstrap.prepareAll();
  final lease = await SanadRuntimeOwnership.acquire();
  stdout.writeln('locked');
  await stdout.flush();
  await stdin.first;
  await lease.release();
}
