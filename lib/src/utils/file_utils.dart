import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

// Utility functions for file operations
class FileUtils {
  static final RegExp _safeExtension = RegExp(r'^\.[A-Za-z0-9]{1,8}$');

  static const Map<String, String> _extensionsByMimeType = {
    'image/jpeg': '.jpg',
    'image/jpg': '.jpg',
    'image/png': '.png',
    'image/webp': '.webp',
    'image/gif': '.gif',
    'image/heic': '.heic',
    'image/heif': '.heif',
    'image/svg+xml': '.svg',
    'video/mp4': '.mp4',
    'video/quicktime': '.mov',
    'video/webm': '.webm',
    'video/3gpp': '.3gp',
    'audio/mpeg': '.mp3',
    'audio/mp4': '.m4a',
    'audio/aac': '.aac',
    'audio/ogg': '.ogg',
    'audio/wav': '.wav',
    'audio/x-wav': '.wav',
    'application/pdf': '.pdf',
    'application/json': '.json',
    'application/zip': '.zip',
    'text/plain': '.txt',
    'text/csv': '.csv',
  };

  /// Stable, collision-resistant key for a URL (hex SHA-256).
  ///
  /// Used as the on-disk filename, so two URLs that share a basename
  /// (`a/photo.jpg`, `b/photo.jpg`) never overwrite each other.
  static String cacheKey(String url) =>
      sha256.convert(utf8.encode(url)).toString();

  /// File extension (with the dot) for a cached file, or '' if unknown.
  ///
  /// Prefers the extension in the URL path, then the response Content-Type.
  /// Players such as AVPlayer on iOS need a correct extension to open a file.
  static String extensionFor(String url, [String? contentType]) {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      final ext = path.extension(uri.path).toLowerCase();
      if (_safeExtension.hasMatch(ext)) return ext;
    }
    if (contentType != null) {
      final mimeType = contentType.split(';').first.trim().toLowerCase();
      return _extensionsByMimeType[mimeType] ?? '';
    }
    return '';
  }

  /// Turns a caller-supplied folder name into a safe relative path.
  ///
  /// `/` still nests folders, but empty, `.` and `..` segments are dropped so
  /// a folder name can never point outside the cache directory.
  static String sanitizeFolderName(String folderName) {
    final segments = folderName
        .replaceAll('\u0000', '')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList();
    return segments.isEmpty ? 'default' : path.joinAll(segments);
  }

  /// Filename scheme used before 0.1.10. Only used to find and migrate
  /// files cached by older versions.
  static String legacyFilename(String url) {
    final uri = Uri.parse(url);
    final filename = path.basename(uri.path);

    // If path has no filename, use the hash of the URL
    if (filename.isEmpty || !filename.contains('.')) {
      return url.hashCode.toString();
    }

    return filename;
  }

  // Generate a filename from URL
  @Deprecated('Collides for URLs that share a basename. Use cacheKey instead.')
  static String generateFilename(String url) => legacyFilename(url);

  // Format bytes to a human-readable format
  static String formatBytes(int bytes, {int decimals = 2}) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    final i = min((log(bytes) / log(1024)).floor(), suffixes.length - 1);
    return '${(bytes / pow(1024, i)).toStringAsFixed(decimals)} ${suffixes[i]}';
  }
}
