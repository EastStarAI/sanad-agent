import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../scripts/sanad_dev/local_gateway_credential.dart';

Future<File> writeCredential(Directory home, String value) async {
  final file = File('${home.path}${Platform.pathSeparator}.local_token');
  await file.writeAsString(value);
  if (!Platform.isWindows) {
    final result = await Process.run('chmod', ['600', file.path]);
    expect(result.exitCode, 0);
  }
  return file;
}

void main() {
  late Directory sanadHome;

  setUp(() async {
    sanadHome = await Directory.systemTemp.createTemp(
      'sanad-dev-local-credential-test-',
    );
  });

  tearDown(() async {
    if (sanadHome.existsSync()) await sanadHome.delete(recursive: true);
  });

  test('reads and attaches the selected runtime credential', () async {
    const secret = 'sanad-dev-header-secret';
    await writeCredential(sanadHome, '$secret\n');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final captured = <String?>[];
    server.listen((request) async {
      captured.add(request.headers.value(localGatewayCredentialHeader));
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    });

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final uri = Uri.parse('http://127.0.0.1:${server.port}/health');
    final request = await client.getUrl(uri);
    await authorizeLocalGatewayRequest(request, sanadHome.path);
    final response = await request.close();
    await response.drain<void>();

    expect(captured.single, secret);
    expect(uri.toString(), isNot(contains(secret)));
    expect(Platform.environment.values, isNot(contains(secret)));
  });

  test('fails closed for missing, empty, and symlink tokens', () async {
    await expectLater(
      readLocalGatewayCredential(sanadHome.path),
      throwsA(isA<LocalGatewayCredentialUnavailable>()),
    );
    final token = await writeCredential(sanadHome, ' \n');
    await expectLater(
      readLocalGatewayCredential(sanadHome.path),
      throwsA(isA<LocalGatewayCredentialUnavailable>()),
    );
    if (!Platform.isWindows) {
      await token.delete();
      final target = File(
        '${sanadHome.path}${Platform.pathSeparator}token-target',
      );
      await target.writeAsString('secret');
      await Link(token.path).create(target.path);
      await expectLater(
        readLocalGatewayCredential(sanadHome.path),
        throwsA(isA<LocalGatewayCredentialUnavailable>()),
      );
    }
  });

  test('fails closed for permissive Unix token modes', () async {
    if (Platform.isWindows) return;
    final token = await writeCredential(sanadHome, 'secret');
    expect((await Process.run('chmod', ['644', token.path])).exitCode, 0);
    await expectLater(
      readLocalGatewayCredential(sanadHome.path),
      throwsA(isA<LocalGatewayCredentialUnavailable>()),
    );
  });

  test('fails closed for a symlinked Sanad Home root', () async {
    if (Platform.isWindows) return;
    final parent = await Directory.systemTemp.createTemp('sanad-dev-link-');
    addTearDown(() => parent.delete(recursive: true));
    final realHome = await Directory('${parent.path}/real').create();
    await writeCredential(realHome, 'secret');
    final linkedHome = Link('${parent.path}/linked');
    await linkedHome.create(realHome.path);

    await expectLater(
      readLocalGatewayCredential(linkedHome.path),
      throwsA(isA<LocalGatewayCredentialUnavailable>()),
    );
  });
}
