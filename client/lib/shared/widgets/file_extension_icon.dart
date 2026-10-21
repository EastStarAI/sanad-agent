import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class FileExtensionIcon extends StatelessWidget {
  final String fileName;
  final double? size;

  const FileExtensionIcon({
    super.key,
    required this.fileName,
    this.size,
  });

  static String _getSvgAssetPath(String fileName) {
    final lowerName = fileName.toLowerCase().trim();

    // Direct filename / key overrides
    if (lowerName == 'dockerfile' || lowerName.endsWith('.dockerfile')) {
      return 'assets/file_icons/docker.svg';
    }
    if (lowerName.startsWith('.env') || lowerName == '.env') {
      return 'assets/file_icons/settings.svg';
    }

    // Extract extension (e.g. "main.dart" -> "dart", "archive.tar.gz" -> "gz")
    String ext = '';
    if (lowerName.contains('.')) {
      ext = lowerName.split('.').last;
    } else {
      ext = lowerName;
    }

    switch (ext) {
      case 'dart':
        return 'assets/file_icons/dart.svg';
      case 'py':
      case 'pyw':
      case 'python':
        return 'assets/file_icons/python.svg';
      case 'js':
      case 'mjs':
      case 'cjs':
      case 'jsx':
        return 'assets/file_icons/javascript.svg';
      case 'ts':
      case 'tsx':
        return 'assets/file_icons/typescript.svg';
      case 'html':
      case 'htm':
        return 'assets/file_icons/html.svg';
      case 'css':
      case 'scss':
      case 'sass':
      case 'less':
        return 'assets/file_icons/css.svg';
      case 'json':
      case 'json5':
        return 'assets/file_icons/json.svg';
      case 'yaml':
      case 'yml':
        return 'assets/file_icons/yaml.svg';
      case 'xml':
        return 'assets/file_icons/xml.svg';
      case 'sh':
      case 'bash':
      case 'zsh':
      case 'fish':
      case 'bat':
        return 'assets/file_icons/console.svg';
      case 'c':
      case 'h':
        return 'assets/file_icons/c.svg';
      case 'cpp':
      case 'hpp':
      case 'cc':
      case 'cxx':
        return 'assets/file_icons/cpp.svg';
      case 'go':
        return 'assets/file_icons/go.svg';
      case 'rs':
        return 'assets/file_icons/rust.svg';
      case 'java':
        return 'assets/file_icons/java.svg';
      case 'kt':
      case 'kts':
        return 'assets/file_icons/kotlin.svg';
      case 'php':
        return 'assets/file_icons/php.svg';
      case 'rb':
        return 'assets/file_icons/ruby.svg';
      case 'swift':
        return 'assets/file_icons/swift.svg';
      case 'sql':
      case 'db':
      case 'sqlite':
        return 'assets/file_icons/database.svg';
      case 'docker':
        return 'assets/file_icons/docker.svg';
      case 'env':
      case 'config':
      case 'conf':
      case 'ini':
      case 'toml':
        return 'assets/file_icons/settings.svg';
      case 'md':
      case 'markdown':
        return 'assets/file_icons/markdown.svg';
      case 'pdf':
        return 'assets/file_icons/pdf.svg';
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'svg':
      case 'webp':
      case 'ico':
      case 'bmp':
      case 'heic':
      case 'heif':
      case 'tif':
      case 'tiff':
      case 'avif':
        return 'assets/file_icons/image.svg';
      case 'zip':
      case 'tar':
      case 'gz':
      case '7z':
      case 'rar':
      case 'bz2':
        return 'assets/file_icons/zip.svg';
      case 'txt':
      case 'log':
        return 'assets/file_icons/document.svg';
      default:
        return 'assets/file_icons/file.svg';
    }
  }

  @override
  Widget build(BuildContext context) {
    final lowerName = fileName.toLowerCase();
    final iconSize = size ?? 20.0;

    // 1. Check for Terminal / Command keys -> Use standard Material Icon
    if (lowerName == 'terminal' || lowerName == 'shell' || lowerName == 'cmd' || lowerName == 'ran') {
      return SvgPicture.asset(
        'assets/file_icons/console.svg',
        width: iconSize,
        height: iconSize,
        fit: BoxFit.contain,
        colorFilter: ColorFilter.mode(Colors.grey.withValues(alpha: 0.7), BlendMode.srcIn),
      );
    }

    // 2. Check for Search / Grep / Glob keys -> Use standard Material Icon
    if (lowerName == 'search' || lowerName == 'grep' || lowerName == 'glob') {
      return Icon(
        Icons.search_rounded,
        size: iconSize,
        color: Colors.grey.withValues(alpha: 0.7),
      );
    }

    final assetPath = _getSvgAssetPath(fileName);

    return SvgPicture.asset(
      assetPath,
      width: iconSize,
      height: iconSize,
      fit: BoxFit.contain,
    );
  }
}
