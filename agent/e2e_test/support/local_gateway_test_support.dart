import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';

String? readLocalGatewayTestToken(String sanadHomePath) {
  final tokenFile = File(
    p.join(sanadHomePath, LocalGatewayCredentials.relativePath),
  );
  if (!tokenFile.existsSync()) return null;
  final token = tokenFile.readAsStringSync().trim();
  return token.isEmpty ? null : token;
}

void authorizeLocalGatewayTestRequest(
  HttpClientRequest request,
  String sanadHomePath,
) {
  final token = readLocalGatewayTestToken(sanadHomePath);
  if (token != null) {
    request.headers.set(LocalGatewayCredentials.headerName, token);
  }
}

Future<WebSocket> connectAuthenticatedLocalGateway({
  required int port,
  required String sanadHomePath,
}) {
  final token = readLocalGatewayTestToken(sanadHomePath);
  if (token == null) {
    throw StateError('Local Gateway credential is not ready.');
  }
  return WebSocket.connect(
    'ws://127.0.0.1:$port/ws',
    headers: {LocalGatewayCredentials.headerName: token},
  );
}
