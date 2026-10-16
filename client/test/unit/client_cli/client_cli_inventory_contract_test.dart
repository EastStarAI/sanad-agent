import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('device inventory DI contract', () {
    late String injectionSource;

    setUpAll(() {
      injectionSource = File('lib/core/di/injection.dart').readAsStringSync();
    });

    test('IDeviceRepository is one shared, lazily initialized inventory owner', () {
      expect(
        injectionSource,
        contains('registerLazySingleton<IDeviceRepository>'),
        reason:
            'The Client CLI host and the device cubit must share one initialized '
            'DeviceManager; a factory hands the CLI host an uninitialized '
            'repository whose agent list is always empty.',
      );
      expect(
        injectionSource,
        isNot(contains('registerFactory<IDeviceRepository>')),
      );
    });

    test('ClientCliHost reads the shared device repository', () {
      final hostBlock = RegExp(
        r'registerLazySingleton<ClientCliHost>\(([\s\S]*?)\n  \}',
      ).firstMatch(injectionSource)?.group(1);

      expect(hostBlock, isNotNull, reason: 'ClientCliHost registration is missing');
      expect(
        hostBlock,
        contains('deviceRepository: getIt<IDeviceRepository>()'),
        reason: 'Client CLI device discovery must use the shared inventory owner',
      );
    });
  });
}
