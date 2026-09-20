import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

void main() {
  test('daemon startup does not require provider configuration', () async {
    final configUri = await Isolate.resolvePackageUri(
      Uri.parse('package:sanad_agent/core/config.dart'),
    );
    expect(configUri, isNotNull);

    final packageRoot = File.fromUri(configUri!).parent.parent.parent;
    final daemon = File('${packageRoot.path}/bin/daemon.dart');
    expect(daemon.existsSync(), isTrue);

    final source = daemon.readAsStringSync();
    expect(source, isNot(contains('config.isValid')));
    expect(source, isNot(contains('Configuration is not valid')));
    expect(source.contains('runAgentStateMaintenanceSafely()'), isTrue);
    final maintenanceCall = source.indexOf('runAgentStateMaintenanceSafely()');
    expect(
      source.indexOf('_restoreDurableStateSafely'),
      lessThan(source.indexOf('gatewayManager.start()')),
    );
    expect(
      maintenanceCall,
      greaterThan(source.indexOf('gatewayManager.start()')),
    );
    expect(
      maintenanceCall,
      greaterThan(source.indexOf('Daemon is running. Press Ctrl+C')),
    );
  });
}
