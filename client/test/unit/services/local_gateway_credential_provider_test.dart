import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_http_client.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_uri_policy.dart';

class _FailIfReadProvider extends LocalGatewayCredentialProvider {
  @override
  Future<Map<String, String>> headers() {
    throw StateError('credential must not be read');
  }
}

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
      'sanad-local-credential-test-',
    );
  });

  tearDown(() async {
    if (sanadHome.existsSync()) await sanadHome.delete(recursive: true);
  });

  test('reads the token only from the selected Sanad Home', () async {
    await writeCredential(sanadHome, 'local-secret\n');
    final provider = LocalGatewayCredentialProvider(
      sanadHomePath: sanadHome.path,
    );

    expect(await provider.read(), 'local-secret');
    expect(await provider.headers(), {
      LocalGatewayCredentialProvider.headerName: 'local-secret',
    });
  });

  test('rejects missing, empty, and symlink credential files', () async {
    final provider = LocalGatewayCredentialProvider(
      sanadHomePath: sanadHome.path,
    );
    await expectLater(
      provider.read(),
      throwsA(isA<LocalGatewayCredentialException>()),
    );

    final token = await writeCredential(sanadHome, '   \n');
    await expectLater(
      provider.read(),
      throwsA(isA<LocalGatewayCredentialException>()),
    );

    if (!Platform.isWindows) {
      await token.delete();
      final target = File(
        '${sanadHome.path}${Platform.pathSeparator}outside-token',
      );
      await target.writeAsString('outside-secret');
      await Link(token.path).create(target.path);
      await expectLater(
        provider.read(),
        throwsA(isA<LocalGatewayCredentialException>()),
      );
    }
  });

  test('rejects a credential readable by other users', () async {
    if (Platform.isWindows) return;
    final token = await writeCredential(sanadHome, 'secret');
    expect((await Process.run('chmod', ['644', token.path])).exitCode, 0);
    final provider = LocalGatewayCredentialProvider(
      sanadHomePath: sanadHome.path,
    );
    await expectLater(
      provider.read(),
      throwsA(
        isA<LocalGatewayCredentialException>().having(
          (error) => error.code,
          'code',
          'credential_permissions',
        ),
      ),
    );
  });

  test('rejects a symlinked Sanad Home root', () async {
    if (Platform.isWindows) return;
    final parent = await Directory.systemTemp.createTemp('sanad-home-link-');
    addTearDown(() => parent.delete(recursive: true));
    final realHome = await Directory('${parent.path}/real').create();
    await writeCredential(realHome, 'secret');
    final linkedHome = Link('${parent.path}/linked');
    await linkedHome.create(realHome.path);

    final provider = LocalGatewayCredentialProvider(
      sanadHomePath: linkedHome.path,
    );
    await expectLater(
      provider.read(),
      throwsA(
        isA<LocalGatewayCredentialException>().having(
          (error) => error.code,
          'code',
          'unsafe_home',
        ),
      ),
    );
  });

  test('HTTP client sends the credential in a header, never the URL', () async {
    const secret = 'header-only-secret';
    await writeCredential(sanadHome, secret);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    late final Uri receivedUri;
    late final String? receivedHeader;
    final requestHandled = Completer<void>();
    server.listen((request) async {
      receivedUri = request.uri;
      receivedHeader = request.headers.value(
        LocalGatewayCredentialProvider.headerName,
      );
      request.response.write(jsonEncode({'status': 'ok'}));
      await request.response.close();
      requestHandled.complete();
    });

    final client = LocalGatewayHttpClient(
      credentialProvider: LocalGatewayCredentialProvider(
        sanadHomePath: sanadHome.path,
      ),
    );
    final response = await client.get(
      Uri.parse('http://127.0.0.1:${server.port}/health'),
    );
    await requestHandled.future;

    expect(response.statusCode, HttpStatus.ok);
    expect(receivedHeader, secret);
    expect(receivedUri.toString(), isNot(contains(secret)));
    expect(Platform.environment.values, isNot(contains(secret)));
  });

  test('HTTP client rejects non-loopback before reading credentials', () async {
    final client = LocalGatewayHttpClient(
      credentialProvider: _FailIfReadProvider(),
    );

    await expectLater(
      client.get(Uri.parse('http://192.168.1.10:58085/health')),
      throwsA(isA<LocalGatewayUriViolation>()),
    );
  });

  test('HTTP client never follows redirects with the credential', () async {
    const secret = 'redirect-safe-secret';
    await writeCredential(sanadHome, secret);
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var targetRequests = 0;
    target.listen((request) async {
      targetRequests++;
      await request.response.close();
    });
    addTearDown(() => target.close(force: true));
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    source.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://127.0.0.1:${target.port}/capture',
      );
      await request.response.close();
    });
    addTearDown(() => source.close(force: true));
    final client = LocalGatewayHttpClient(
      credentialProvider: LocalGatewayCredentialProvider(
        sanadHomePath: sanadHome.path,
      ),
    );

    final response = await client.get(
      Uri.parse('http://127.0.0.1:${source.port}/redirect'),
    );

    expect(response.statusCode, HttpStatus.found);
    expect(targetRequests, 0);
  });
}
