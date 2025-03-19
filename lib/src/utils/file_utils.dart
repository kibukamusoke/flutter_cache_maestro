import 'dart:math';
import 'package:path/path.dart' as path;

// Utility functions for file operations
class FileUtils {
  // Generate a filename from URL
  static String generateFilename(String url) {
    final uri = Uri.parse(url);
    final filename = path.basename(uri.path);

    // If path has no filename, use the hash of the URL
    if (filename.isEmpty || !filename.contains('.')) {
      return url.hashCode.toString();
    }

    return filename;
  }

  // Format bytes to a human-readable format
  static String formatBytes(int bytes, {int decimals = 2}) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(decimals)} ${suffixes[i]}';
  }
}
