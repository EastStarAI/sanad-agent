import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/web_origin.dart';

const _home = '/Users/dev/.sanad/dev/homes/test-home-2-1a2b3c4d';
const _hostedPortal = 'https://portal.sanad.eaststarai.com';

void main() {
  group('deterministic Web origin derivation', () {
    test('is stable for one Home, slot, and environment', () {
      final first = deriveSanadDevWebPort(
        sanadHome: _home,
        clientEnvironment: 'local',
        clientInstanceSlot: 'web-primary',
      );
      final second = deriveSanadDevWebPort(
        sanadHome: _home,
        clientEnvironment: 'local',
        clientInstanceSlot: 'web-primary',
      );

      expect(first, second);
      expect(first, inInclusiveRange(52000, 52999));
    });

    test('stays inside the reserved range and clear of other runtimes', () {
      expect(sanadDevWebPortRangeStart, greaterThan(51999));
      expect(sanadDevWebPortRangeEnd, lessThan(58085));

      for (final slot in ['', 'web-primary', 'web-secondary', 'ios-primary']) {
        for (final environment in ['local', 'dev', 'staging', 'prod']) {
          final port = deriveSanadDevWebPort(
            sanadHome: _home,
            clientEnvironment: environment,
            clientInstanceSlot: slot.isEmpty ? null : slot,
          );
          expect(port, inInclusiveRange(52000, 52999));
        }
      }
    });

    test('separates slots, environments, and Homes', () {
      final base = deriveSanadDevWebPort(
        sanadHome: _home,
        clientEnvironment: 'local',
      );
      final otherSlot = deriveSanadDevWebPort(
        sanadHome: _home,
        clientEnvironment: 'local',
        clientInstanceSlot: 'web-secondary',
      );
      final otherEnvironment = deriveSanadDevWebPort(
        sanadHome: _home,
        clientEnvironment: 'prod',
      );
      final otherHome = deriveSanadDevWebPort(
        sanadHome: '$_home-other',
        clientEnvironment: 'local',
      );

      expect(
        {base, otherSlot, otherEnvironment, otherHome},
        hasLength(4),
        reason: 'a shared origin would share browser storage across identities',
      );
    });

    test('rejects a missing Home or environment', () {
      expect(
        () =>
            deriveSanadDevWebPort(sanadHome: '  ', clientEnvironment: 'local'),
        throwsFormatException,
      );
      expect(
        () => deriveSanadDevWebPort(sanadHome: _home, clientEnvironment: ''),
        throwsFormatException,
      );
    });
  });

  group('hosted Portal detection', () {
    test('a loopback or absent Portal is not hosted', () {
      for (final url in [
        'http://127.0.0.1:8083',
        'http://localhost:8083',
        'http://[::1]:8083',
        '',
      ]) {
        expect(isSanadDevHostedPortal(url), isFalse, reason: url);
      }
    });

    test('a remote Portal is hosted', () {
      for (final url in [_hostedPortal, 'https://dev.portal.example.test']) {
        expect(isSanadDevHostedPortal(url), isTrue, reason: url);
      }
    });
  });

  group('origin selection', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp(
        'sanad-dev-web-origin-record-',
      );
      addTearDown(() => home.delete(recursive: true));
    });

    Future<int> choose({
      String environment = 'local',
      String? slot,
      Map<String, String> environmentVariables = const {},
      Future<bool> Function(int port)? portIsFree,
    }) => chooseSanadDevWebPort(
      sanadHome: home.path,
      clientEnvironment: environment,
      processEnvironment: environmentVariables,
      clientInstanceSlot: slot,
      portIsFree: portIsFree ?? (_) async => true,
    );

    test('keeps an explicit deployment-pinned port', () async {
      expect(
        await choose(
          environmentVariables: {sanadDevWebPortEnvironmentKey: '55025'},
        ),
        55025,
        reason: 'an existing pinned local stack must not be moved',
      );
    });

    test('rejects an invalid override instead of falling back', () async {
      for (final value in ['0', '70000', 'eighty']) {
        await expectLater(
          choose(environmentVariables: {sanadDevWebPortEnvironmentKey: value}),
          throwsFormatException,
        );
      }
    });

    test('derives the same way for a hosted environment', () async {
      final port = await choose(environment: 'prod');

      expect(port, inInclusiveRange(52000, 52999));
      expect(
        port,
        deriveSanadDevWebPort(sanadHome: home.path, clientEnvironment: 'prod'),
        reason: 'a hosted Portal no longer changes which port is served',
      );
    });

    test('refuses a busy origin instead of moving to another one', () async {
      final derived = deriveSanadDevWebPort(
        sanadHome: home.path,
        clientEnvironment: 'prod',
      );
      await expectLater(
        choose(environment: 'prod', portIsFree: (_) async => false),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('http://localhost:$derived'),
              contains(sanadDevWebPortEnvironmentKey),
              contains('prod'),
            ),
          ),
        ),
      );
    });

    test('reuses the recorded origin of the same slot on a restart', () async {
      final first = await choose();
      final second = await choose();

      expect(second, first);
    });

    test('records an explicit override so the launcher can carry it', () async {
      await choose(
        environmentVariables: {sanadDevWebPortEnvironmentKey: '55025'},
      );

      final record = await readSanadDevWebOriginRecord(sanadHome: home.path);
      expect(record?.port, 55025);
      expect(record?.environment, 'local');
    });

    test('trusts a recorded origin from the same environment', () async {
      await writeSanadDevWebOriginRecord(
        sanadHome: home.path,
        clientInstanceSlot: null,
        environment: 'local',
        port: 55025,
      );

      expect(await choose(), 55025, reason: 'a restart keeps its origin');
    });

    test('ignores a record written for another environment', () async {
      await choose(
        environmentVariables: {sanadDevWebPortEnvironmentKey: '55025'},
      );

      final port = await choose(environment: 'prod');
      expect(
        port,
        deriveSanadDevWebPort(sanadHome: home.path, clientEnvironment: 'prod'),
      );
    });

    test('separates the browser origins of two slots', () async {
      final primary = await choose(environment: 'prod');
      final secondary = await choose(
        environment: 'prod',
        slot: 'web-secondary',
      );

      expect(secondary, isNot(primary));
      expect(secondary, inInclusiveRange(52000, 52999));
    });

    test('names the override when the derived origin is busy', () async {
      await expectLater(
        choose(portIsFree: (_) async => false),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains(sanadDevWebPortEnvironmentKey), contains('local')),
          ),
        ),
      );
    });
  });

  group('origin record', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp(
        'sanad-dev-web-origin-file-',
      );
      addTearDown(() => home.delete(recursive: true));
    });

    test('lives beside the other runtime state of the Home', () {
      expect(
        sanadDevWebOriginRecordPath(home.path),
        '${home.path}${Platform.pathSeparator}dev'
        '${Platform.pathSeparator}web-origin.json',
      );
    });

    test('is absent until an origin is chosen', () async {
      expect(await readSanadDevWebOriginRecord(sanadHome: home.path), isNull);
    });

    test('keeps one port per slot', () async {
      await writeSanadDevWebOriginRecord(
        sanadHome: home.path,
        clientInstanceSlot: null,
        environment: 'prod',
        port: 52123,
      );
      await writeSanadDevWebOriginRecord(
        sanadHome: home.path,
        clientInstanceSlot: 'web-secondary',
        environment: 'prod',
        port: 52223,
      );

      final primary = await readSanadDevWebOriginRecord(sanadHome: home.path);
      final secondary = await readSanadDevWebOriginRecord(
        sanadHome: home.path,
        clientInstanceSlot: 'web-secondary',
      );
      expect(primary?.port, 52123);
      expect(secondary?.port, 52223);
    });

    test('loses only the preference when the file is corrupt', () async {
      final file = File(sanadDevWebOriginRecordPath(home.path));
      await file.parent.create(recursive: true);
      await file.writeAsString('{"slots":');

      expect(await readSanadDevWebOriginRecord(sanadHome: home.path), isNull);
      await writeSanadDevWebOriginRecord(
        sanadHome: home.path,
        clientInstanceSlot: null,
        environment: 'local',
        port: 52123,
      );
      expect(
        (await readSanadDevWebOriginRecord(sanadHome: home.path))?.port,
        52123,
      );
    });

    test('records the environment with the port', () async {
      await writeSanadDevWebOriginRecord(
        sanadHome: home.path,
        clientInstanceSlot: 'web-primary',
        environment: 'prod',
        port: 52347,
      );

      final record = await readSanadDevWebOriginRecord(
        sanadHome: home.path,
        clientInstanceSlot: 'web-primary',
      );
      expect(record?.environment, 'prod');
      final decoded = jsonDecode(
        await File(sanadDevWebOriginRecordPath(home.path)).readAsString(),
      );
      expect(decoded['version'], 1);
    });
  });
}
