import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class WindowsLauncherBundle {
  static const magic = 'SANADLCHBUNDLE1!';
  static const footerLength = 32 + 8 + 16;

  static Future<void> embed({
    required File agent,
    required File launcher,
  }) async {
    final launcherBytes = await launcher.readAsBytes();
    _validateGuiExecutable(launcherBytes);
    final sink = agent.openWrite(mode: FileMode.append);
    sink.add(launcherBytes);
    sink.add(sha256.convert(launcherBytes).bytes);
    final length = ByteData(8)
      ..setUint64(0, launcherBytes.length, Endian.little);
    sink.add(length.buffer.asUint8List());
    sink.add(magic.codeUnits);
    await sink.close();
  }

  static Future<String?> install({
    required String agentExecutable,
    required String binDirectory,
  }) async {
    final source = File(agentExecutable);
    final handle = await source.open();
    try {
      final size = await handle.length();
      if (size < footerLength) return null;
      await handle.setPosition(size - footerLength);
      final footer = await handle.read(footerLength);
      if (footer.length != footerLength ||
          String.fromCharCodes(footer.sublist(40)) != magic) {
        return null;
      }
      final expectedDigest = footer.sublist(0, 32);
      final length = ByteData.sublistView(
        Uint8List.fromList(footer),
        32,
        40,
      ).getUint64(0, Endian.little);
      if (length == 0 || length > size - footerLength) {
        throw const FormatException(
          'Invalid embedded Windows launcher length.',
        );
      }
      await handle.setPosition(size - footerLength - length);
      final bytes = await handle.read(length);
      if (bytes.length != length ||
          !_constantTimeEquals(sha256.convert(bytes).bytes, expectedDigest)) {
        throw const FormatException(
          'Embedded Windows launcher checksum failed.',
        );
      }

      final digest = sha256.convert(bytes).toString();
      final target = File(
        p.join(binDirectory, 'sanad-launcher-${digest.substring(0, 16)}.exe'),
      );
      if (target.existsSync()) {
        final installedDigest = await sha256.bind(target.openRead()).first;
        if (installedDigest.toString() == digest) return target.path;
      }
      await target.parent.create(recursive: true);
      final staged = File('${target.path}.staged');
      if (staged.existsSync()) await staged.delete();
      await staged.writeAsBytes(bytes, flush: true);
      if (target.existsSync()) await target.delete();
      await staged.rename(target.path);
      return target.path;
    } finally {
      await handle.close();
    }
  }

  static void _validateGuiExecutable(List<int> bytes) {
    if (bytes.length < 256 || bytes[0] != 0x4d || bytes[1] != 0x5a) {
      throw const FormatException('Windows launcher is not a PE executable.');
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final peOffset = data.getUint32(0x3c, Endian.little);
    final optionalHeader = peOffset + 24;
    if (optionalHeader + 70 > bytes.length ||
        bytes[peOffset] != 0x50 ||
        bytes[peOffset + 1] != 0x45 ||
        bytes[peOffset + 2] != 0 ||
        bytes[peOffset + 3] != 0 ||
        data.getUint16(optionalHeader + 68, Endian.little) != 2) {
      throw const FormatException(
        'Windows launcher must use the GUI subsystem.',
      );
    }
  }

  static bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
