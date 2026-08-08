import 'package:http/http.dart' as http;

import 'local_gateway_credential_provider.dart';
import 'local_gateway_uri_policy.dart';

class LocalGatewayHttpClient {
  const LocalGatewayHttpClient({
    this.credentialProvider = const LocalGatewayCredentialProvider(),
  });

  final LocalGatewayCredentialProvider credentialProvider;

  Future<http.Response> get(Uri uri) => _send('GET', uri);

  Future<http.Response> post(Uri uri) => _send('POST', uri);

  Future<http.Response> _send(String method, Uri uri) async {
    final safeUri = LocalGatewayUriPolicy.requireHttp(uri);
    final request = http.Request(method, safeUri)
      ..followRedirects = false
      ..headers.addAll(await credentialProvider.headers());
    final client = http.Client();
    try {
      return await http.Response.fromStream(await client.send(request));
    } finally {
      client.close();
    }
  }
}
