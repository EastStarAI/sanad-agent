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

  test('a clean shutdown removes the record this process published', () async {
    // The daemon shutdown hook knows only its own pid: it must remove the
    // record without being told the port, and it must leave no claim file.
    await LocalGatewayEndpointRecord.write(
      host: '127.0.0.1',
      port: 58130,
      processId: 4711,
    );

    expect(await LocalGatewayEndpointRecord.removeIfOwned(processId: 4711),
        isTrue);

    expect(recordFile().existsSync(), isFalse);
    expect(
      recordFile().parent
          .listSync()
          .whereType<File>()
          .map((file) => p.basename(file.path)),
      isNot(contains('${p.basename(recordFile().path)}.removing-4711')),
    );
  });

  test('a shutdown never removes a successor runtime record', () async {
    // A newer runtime already republished the endpoint under a different pid;
    // the draining daemon must not delete it even without a port to compare.
    await LocalGatewayEndpointRecord.write(
      host: '127.0.0.1',
      port: 58131,
      processId: 4712,
    );

    expect(await LocalGatewayEndpointRecord.removeIfOwned(processId: 4711),
        isFalse);

    expect(LocalGatewayEndpointRecord.tryRead()?.ownerProcessId, 4712);
  });

  test('a shutdown with a known port keeps a different endpoint', () async {
    await LocalGatewayEndpointRecord.write(
      host: '127.0.0.1',
      port: 58132,
      processId: 4711,
    );

    expect(
      await LocalGatewayEndpointRecord.removeIfOwned(port: 58133, processId: 4711),
      isFalse,
    );
    expect(recordFile().existsSync(), isTrue);
  });

  test('removing an absent record is a no-op', () async {
    expect(await LocalGatewayEndpointRecord.removeIfOwned(processId: 4711),
        isFalse);
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

  test('a record naming a non-loopback host is ignored', () {
    recordFile().writeAsStringSync(
      jsonEncode({
        'schema': LocalGatewayEndpointRecord.schemaVersion,
        'home_id': sanadHomeIdentity(getSanadHome()),
        'host': '10.0.0.5',
        'port': 58127,
        'pid': pid,
      }),
    );

    expect(LocalGatewayEndpointRecord.tryRead(), isNull);
  });

  test('a record that is not owner-only is ignored', () {
    if (Platform.isWindows) return;
    recordFile().writeAsStringSync(
      jsonEncode({
        'schema': LocalGatewayEndpointRecord.schemaVersion,
        'home_id': sanadHomeIdentity(getSanadHome()),
        'host': '127.0.0.1',
        'port': 58128,
        'pid': pid,
      }),
    );
    Process.runSync('chmod', ['644', recordFile().path]);

    expect(LocalGatewayEndpointRecord.tryRead(), isNull);
  });

  test('a record without an owner process id is ignored', () {
    // `write` always persists one, so a record without it is corrupt and its
    // liveness cannot be checked.
    for (final owner in <Object?>[null, 0, '4711']) {
      final payload = <String, Object?>{
        'schema': LocalGatewayEndpointRecord.schemaVersion,
        'home_id': sanadHomeIdentity(getSanadHome()),
        'host': '127.0.0.1',
        'port': 58129,
      };
      if (owner != null) payload['pid'] = owner;
      recordFile().writeAsStringSync(jsonEncode(payload));

      expect(
        LocalGatewayEndpointRecord.tryRead(),
        isNull,
        reason: 'pid $owner',
      );
    }
  });

  test('owner liveness separates a live publisher from a dead one', () {
    expect(isProcessAlive(pid), isTrue);
    expect(isProcessAlive(0), isFalse);
    expect(isProcessAlive(4194304), isFalse);
  });
}
