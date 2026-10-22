import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_identity.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_endpoint_record.dart';

import '../../../support/isolated_sanad_test_home.dart';

void main() {
  useIsolatedSanadTestHome();

  File recordFile() => File(
    SanadHomeBootstrap.resolveChild(LocalGatewayEndpointRecord.relativePath),
  );

  test('write publishes the endpoint bound to this Home', () async {
    await LocalGatewayEndpointRecord.write(
      host: '127.0.0.1',
      port: 58123,
      processId: 4711,
    );

    final record = LocalGatewayEndpointRecord.tryRead();

    expect(record, isNotNull);
    expect(record!.host, '127.0.0.1');
    expect(record.port, 58123);
    expect(record.ownerProcessId, 4711);
    expect(record.homeId, sanadHomeIdentity(getSanadHome()));
    if (!Platform.isWindows) {
      expect(recordFile().statSync().mode & 0x1ff, 0x180);
    }
  });

  test('a record from another Home is readable but identifiable', () async {
    final otherHome = Directory.systemTemp.createTempSync(
      'sanad-endpoint-other-home-',
    );
    addTearDown(() => otherHome.deleteSync(recursive: true));

    recordFile().writeAsStringSync(
      jsonEncode({
        'schema': LocalGatewayEndpointRecord.schemaVersion,
        'home_id': sanadHomeIdentity(otherHome.path),
        'host': '127.0.0.1',
        'port': 58124,
        'pid': 1,
      }),
    );

    final record = LocalGatewayEndpointRecord.tryRead();

    expect(record?.port, 58124);
    expect(record?.homeId, isNot(sanadHomeIdentity(getSanadHome())));
  });

  test('malformed or foreign records are ignored', () {
    recordFile().writeAsStringSync('not json');
    expect(LocalGatewayEndpointRecord.tryRead(), isNull);

    recordFile().writeAsStringSync(
      jsonEncode({'schema': 99, 'home_id': 'x', 'host': 'h', 'port': 1}),
    );
    expect(LocalGatewayEndpointRecord.tryRead(), isNull);

    recordFile().writeAsStringSync(
      jsonEncode({
        'schema': LocalGatewayEndpointRecord.schemaVersion,
        'home_id': 'x',
        'host': 'h',
        'port': 0,
      }),
    );
    expect(LocalGatewayEndpointRecord.tryRead(), isNull);

    recordFile().deleteSync();
    expect(LocalGatewayEndpointRecord.tryRead(), isNull);
  });

  test('removeIfOwned keeps a record another process published', () async {
    await LocalGatewayEndpointRecord.write(
      host: '127.0.0.1',
      port: 58125,
      processId: 999999,
    );

    await LocalGatewayEndpointRecord.removeIfOwned(
      port: 58125,
      processId: 4711,
    );
    expect(recordFile().existsSync(), isTrue);

    await LocalGatewayEndpointRecord.removeIfOwned(
      port: 58125,
      processId: 999999,
    );
    expect(recordFile().existsSync(), isFalse);
  });

  test('the record lives inside the Home it describes', () async {
    await LocalGatewayEndpointRecord.write(host: '127.0.0.1', port: 58126);

    expect(
      p.equals(
        recordFile().path,
        p.join(
          canonicalSanadHomePath(getSanadHome()),
          LocalGatewayEndpointRecord.relativePath,
        ),
      ),
      isTrue,
    );
  });
}
