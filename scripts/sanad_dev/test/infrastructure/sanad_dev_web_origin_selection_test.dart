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

  group('origin authority', () {
    test('a loopback Portal is deployment-owned', () {
      for (final url in [
        'http://127.0.0.1:8083',
        'http://localhost:8083',
        'http://[::1]:8083',
      ]) {
        expect(
          sanadDevWebOriginAuthorityFor(url),
          SanadDevWebOriginAuthority.deploymentOwned,
          reason: url,
        );
      }
    });

    test('no Portal at all is deployment-owned', () {
      expect(
        sanadDevWebOriginAuthorityFor(''),
        SanadDevWebOriginAuthority.deploymentOwned,
      );
    });

    test('a hosted Portal owns its own loopback allowlist', () {
      for (final url in [_hostedPortal, 'https://dev.portal.example.test']) {
        expect(
          sanadDevWebOriginAuthorityFor(url),
          SanadDevWebOriginAuthority.hostedPortal,
          reason: url,
        );
      }
    });
  });

  group('origin candidates', () {
    test('a hosted Portal offers exactly its loopback allowlist', () {
      final candidates = sanadDevWebPortCandidates(
        sanadHome: _home,
        clientEnvironment: 'prod',
        portalUrl: _hostedPortal,
        clientInstanceSlot: 'web-primary',
      );

      expect(candidates, hasLength(sanadDevHostedPortalWebPorts.length));
      expect(candidates.toSet(), sanadDevHostedPortalWebPorts.toSet());
      expect(
        sanadDevHostedPortalWebPorts,
        unorderedEquals([8080, 8082, 5173, 5174, 8083]),
        reason: 'these are the loopback origins every portal deployment allows',
      );
    });

    test(
      'a hosted Portal serves a primary Client from 8080 and slots from the rest',
      () {
        final primary = sanadDevWebPortCandidates(
          sanadHome: _home,
          clientEnvironment: 'prod',
          portalUrl: _hostedPortal,
        );
        final slot = sanadDevWebPortCandidates(
          sanadHome: _home,
          clientEnvironment: 'prod',
          portalUrl: _hostedPortal,
          clientInstanceSlot: 'web-secondary',
        );

        expect(primary.first, 8080);
        expect(primary.toSet(), sanadDevHostedPortalWebPorts.toSet());
        expect(slot.first, isNot(8080));
        expect(slot.toSet(), sanadDevHostedPortalWebPorts.toSet());
        expect(
          sanadDevHostedPortalWebPorts,
          unorderedEquals([8080, 8082, 5173, 5174, 8083]),
          reason: 'these are the loopback origins every portal deployment allows',
        );
      },
    );

    test('a loopback Portal has exactly one derived candidate', () {
      final candidates = sanadDevWebPortCandidates(
        sanadHome: _home,
        clientEnvironment: 'local',
        portalUrl: 'http://127.0.0.1:8083',
        clientInstanceSlot: 'web-primary',
      );

      expect(candidates, [
        deriveSanadDevWebPort(
          sanadHome: _home,
          clientEnvironment: 'local',
          clientInstanceSlot: 'web-primary',
        ),
      ]);
      expect(candidates.single, inInclusiveRange(52000, 52999));
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
      String portalUrl = 'http://127.0.0.1:8083',
      String environment = 'local',
      String? slot,
      Map<String, String> environmentVariables = const {},
      Future<bool> Function(int port)? portIsFree,
    }) => chooseSanadDevWebPort(
      sanadHome: home.path,
      clientEnvironment: environment,
      portalUrl: portalUrl,
      processEnvironment: environmentVariables,
      clientInstanceSlot: slot,
      portIsFree: portIsFree ?? (_) async => true,
    );

    test('keeps an explicit deployment-pinned port', () async {
      expect(
        await choose(
          environmentVariables: {sanadDevWebPortEnvironmentKey: '55025'},
          portalUrl: _hostedPortal,
        ),
        55025,
        reason: 'an existing pinned deployment must not be moved',
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

    test('serves a hosted Portal from its own loopback allowlist', () async {
      final port = await choose(environment: 'prod', portalUrl: _hostedPortal);

      expect(port, 8080);
      expect(sanadDevHostedPortalWebPorts, contains(port));
    });

    test('refuses a busy origin instead of moving to another one', () async {
      await expectLater(
        choose(
          environment: 'prod',
          portalUrl: _hostedPortal,
          portIsFree: (_) async => false,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('http://localhost:8080'),
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

    test('prefers the record over a different free derived port', () async {
      final first = await choose();
      // Everything is free and the derivation still points at [first]; the record
      // only matters when the rotation would move on, which is exactly what a
      // changed candidate order (new Portal) does.
      final afterPortalChange = await choose(
        portalUrl: 'http://localhost:9000',
      );

      expect(afterPortalChange, first);
    });

    test('ignores a record written for another environment', () async {
      await choose(environment: 'local');
      final port = await choose(environment: 'prod', portalUrl: _hostedPortal);

      expect(sanadDevHostedPortalWebPorts, contains(port));
    });

    test('ignores a record outside the current candidate set', () async {
      await writeSanadDevWebOriginRecord(
        sanadHome: home.path,
        clientInstanceSlot: null,
        environment: 'prod',
        port: 3000,
      );

      final port = await choose(environment: 'prod', portalUrl: _hostedPortal);
      expect(sanadDevHostedPortalWebPorts, contains(port));
      expect(port, isNot(3000));
    });

    test('separates the browser origins of two slots', () async {
      final primary = await choose(
        environment: 'prod',
        portalUrl: _hostedPortal,
      );
      final secondary = await choose(
        environment: 'prod',
        portalUrl: _hostedPortal,
        slot: 'web-secondary',
      );

      expect(secondary, isNot(primary));
      expect(sanadDevHostedPortalWebPorts, contains(secondary));
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
        port: 8080,
      );
      await writeSanadDevWebOriginRecord(
        sanadHome: home.path,
        clientInstanceSlot: 'web-secondary',
        environment: 'prod',
        port: 8082,
      );

      final primary = await readSanadDevWebOriginRecord(sanadHome: home.path);
      final secondary = await readSanadDevWebOriginRecord(
        sanadHome: home.path,
        clientInstanceSlot: 'web-secondary',
      );
      expect(primary?.port, 8080);
      expect(secondary?.port, 8082);
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
        port: 5173,
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
