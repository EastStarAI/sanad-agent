import 'dart:io';

const localGatewayCredentialHeader = 'x-sanad-local-token';

class LocalGatewayCredentialUnavailable implements Exception {
  const LocalGatewayCredentialUnavailable();

  @override
  String toString() => 'Local gateway credential is unavailable.';
}

Future<String> readLocalGatewayCredential(String sanadHome) async {
  final normalizedHome = sanadHome.replaceAll(RegExp(r'[\\/]+$'), '');
  final file = File('$normalizedHome${Platform.pathSeparator}.local_token');
  try {
    final homeType = await FileSystemEntity.type(
      normalizedHome,
      followLinks: false,
    );
    if (homeType != FileSystemEntityType.directory) {
      throw const LocalGatewayCredentialUnavailable();
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const LocalGatewayCredentialUnavailable();
    }
    if (!Platform.isWindows && ((await file.stat()).mode & 0x1ff) != 0x180) {
      throw const LocalGatewayCredentialUnavailable();
    }
    final value = (await file.readAsString()).trim();
    if (value.isEmpty) throw const LocalGatewayCredentialUnavailable();
    return value;
  } on LocalGatewayCredentialUnavailable {
    rethrow;
  } on Object {
    throw const LocalGatewayCredentialUnavailable();
  }
}

Future<void> authorizeLocalGatewayRequest(
  HttpClientRequest request,
  String sanadHome,
) async {
  request.headers.set(
    localGatewayCredentialHeader,
    await readLocalGatewayCredential(sanadHome),
  );
}

Future<Map<String, String>> localGatewayCredentialHeaders(
  String sanadHome,
) async => {
  localGatewayCredentialHeader: await readLocalGatewayCredential(sanadHome),
};
