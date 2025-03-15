// You have generated a new plugin project without specifying the `--platforms`
// flag. A plugin project with no platform support was generated. To add a
// platform, run `flutter create -t plugin --platforms <platforms> .` under the
// same directory. You can also find a detailed instruction on how to add
// platforms in the `pubspec.yaml` at
// https://flutter.dev/to/pubspec-plugin-platforms.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

class CacheManager {
  static final CacheManager _instance = CacheManager._internal();
  factory CacheManager() => _instance;
  CacheManager._internal();

  final Map<String, String> _cachedFiles = {};
  final String _baseFolderName = 'cache_maestro';
  int _defaultTTL = 86400; // Default TTL: 1 day in seconds
  bool _redownloadEnabled = false;

  /// Initialize the cache maestro with custom settings
  Future<void> init({
    int? defaultTTL,
    bool? redownloadEnabled,
  }) async {
    if (defaultTTL != null) {
      _defaultTTL = defaultTTL;
    }

    if (redownloadEnabled != null) {
      _redownloadEnabled = redownloadEnabled;
    }

    // Create base directory if it doesn't exist
    final baseDir = await _getBaseDirectory();
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }

    // Start cleanup task
    _startCleanupTask();
  }

  /// Get the base directory for cache storage
  Future<Directory> _getBaseDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(path.join(appDir.path, _baseFolderName));
  }

  /// Get directory for a specific folder
  Future<Directory> _getFolderDirectory(String folderName) async {
    final baseDir = await _getBaseDirectory();
    final folderDir = Directory(path.join(baseDir.path, folderName));
    if (!await folderDir.exists()) {
      await folderDir.create(recursive: true);
    }
    return folderDir;
  }

  /// Get file from cache or download it
  Future<File> getFile(String url, {String? folderName, int? ttl}) async {
    final folder = folderName ?? 'default';
    final folderDir = await _getFolderDirectory(folder);

    // Generate a filename from the URL
    final filename = _generateFilename(url);
    final filePath = path.join(folderDir.path, filename);
    final metadataPath = '$filePath.metadata';
    final file = File(filePath);

    // Check if file exists in cache
    if (await file.exists()) {
      final metadataFile = File(metadataPath);
      if (await metadataFile.exists()) {
        final metadata = await metadataFile.readAsString();
        final creationTime = int.parse(metadata);
        final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final fileAge = currentTime - creationTime;
        final fileTTL = ttl ?? _defaultTTL;

        // Check if file has expired
        if (fileAge < fileTTL && !_redownloadEnabled) {
          return file;
        }
      }
    }

    // Download the file
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);

        // Save metadata (creation time)
        final metadataFile = File(metadataPath);
        await metadataFile.writeAsString(
            (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString());

        _cachedFiles[url] = filePath;
        return file;
      } else {
        throw Exception('Failed to download file: ${response.statusCode}');
      }
    } catch (e) {
      // If downloading fails and we have a cached version, return it
      if (await file.exists()) {
        return file;
      }
      rethrow;
    }
  }

  /// Generate a filename from URL
  String _generateFilename(String url) {
    final uri = Uri.parse(url);
    final filename = path.basename(uri.path);

    // If path has no filename, use the hash of the URL
    if (filename.isEmpty || !filename.contains('.')) {
      return url.hashCode.toString();
    }

    return filename;
  }

  /// Get the size of a specific folder
  Future<int> getFolderSize(String folderName) async {
    final folderDir = await _getFolderDirectory(folderName);
    int totalSize = 0;

    await for (final entity in folderDir.list(recursive: true)) {
      if (entity is File) {
        totalSize += await entity.length();
      }
    }

    return totalSize;
  }

  /// Get all folder names
  Future<List<String>> getAllFolders() async {
    final baseDir = await _getBaseDirectory();
    final List<String> folders = [];

    await for (final entity in baseDir.list()) {
      if (entity is Directory) {
        folders.add(path.basename(entity.path));
      }
    }

    return folders;
  }

  /// Clear a specific folder (delete all files)
  Future<void> clearFolder(String folderName) async {
    final folderDir = await _getFolderDirectory(folderName);
    if (await folderDir.exists()) {
      await folderDir.delete(recursive: true);
      await folderDir.create(recursive: true);
    }
  }

  /// Clear all cached data
  Future<void> clearAllCache() async {
    final baseDir = await _getBaseDirectory();
    if (await baseDir.exists()) {
      await baseDir.delete(recursive: true);
      await baseDir.create(recursive: true);
    }
    _cachedFiles.clear();
  }

  /// Set global TTL (time to live) for cached files
  void setDefaultTTL(int seconds) {
    _defaultTTL = seconds;
  }

  /// Set whether to always redownload files or use cache
  void setRedownloadEnabled(bool enabled) {
    _redownloadEnabled = enabled;
  }

  /// Start background task to clean up expired files
  void _startCleanupTask() {
    Timer.periodic(const Duration(hours: 12), (_) => _cleanupExpiredFiles());
  }

  /// Clean up expired files
  Future<void> _cleanupExpiredFiles() async {
    final baseDir = await _getBaseDirectory();
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await for (final folderEntity in baseDir.list()) {
      if (folderEntity is Directory) {
        await for (final fileEntity in folderEntity.list()) {
          if (fileEntity is File && !fileEntity.path.endsWith('.metadata')) {
            final metadataPath = '${fileEntity.path}.metadata';
            final metadataFile = File(metadataPath);

            if (await metadataFile.exists()) {
              try {
                final metadata = await metadataFile.readAsString();
                final creationTime = int.parse(metadata);
                final fileAge = currentTime - creationTime;

                if (fileAge > _defaultTTL) {
                  await fileEntity.delete();
                  await metadataFile.delete();
                }
              } catch (e) {
                // If metadata is corrupted, delete the file
                await fileEntity.delete();
                await metadataFile.delete();
              }
            } else {
              // If metadata doesn't exist, create it or delete the file
              try {
                await metadataFile.writeAsString(currentTime.toString());
              } catch (e) {
                await fileEntity.delete();
              }
            }
          }
        }
      }
    }
  }
}

/// Widget to display cached media
class CachedMediaWidget extends StatefulWidget {
  final String url;
  final String? folderName;
  final int? ttl;
  final Widget Function(BuildContext, File) builder;
  final Widget? placeholder;
  final Widget? errorWidget;

  const CachedMediaWidget({
    Key? key,
    required this.url,
    this.folderName,
    this.ttl,
    required this.builder,
    this.placeholder,
    this.errorWidget,
  }) : super(key: key);

  @override
  _CachedMediaWidgetState createState() => _CachedMediaWidgetState();
}

class _CachedMediaWidgetState extends State<CachedMediaWidget> {
  late Future<File> _fileFuture;

  @override
  void initState() {
    super.initState();
    _fileFuture = CacheManager().getFile(
      widget.url,
      folderName: widget.folderName,
      ttl: widget.ttl,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: _fileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return widget.placeholder ??
              const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return widget.errorWidget ??
              Center(child: Text('Error: ${snapshot.error}'));
        } else if (snapshot.hasData) {
          return widget.builder(context, snapshot.data!);
        } else {
          return widget.errorWidget ??
              const Center(child: Text('File not available'));
        }
      },
    );
  }
}

/// Convenience widget for cached images
class CachedImage extends StatelessWidget {
  final String url;
  final String? folderName;
  final int? ttl;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final Widget? errorWidget;

  const CachedImage({
    Key? key,
    required this.url,
    this.folderName,
    this.ttl,
    this.fit,
    this.width,
    this.height,
    this.placeholder,
    this.errorWidget,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CachedMediaWidget(
      url: url,
      folderName: folderName,
      ttl: ttl,
      placeholder: placeholder,
      errorWidget: errorWidget,
      builder: (context, file) {
        return Image.file(
          file,
          fit: fit,
          width: width,
          height: height,
        );
      },
    );
  }
}

/// Cache statistics
class CacheStats {
  final int folderCount;
  final Map<String, int> folderSizes;
  final int totalSize;

  CacheStats({
    required this.folderCount,
    required this.folderSizes,
    required this.totalSize,
  });
}

/// Extension for getting cache statistics
extension CacheManagerStats on CacheManager {
  Future<CacheStats> getCacheStats() async {
    final folders = await getAllFolders();
    final Map<String, int> folderSizes = {};
    int totalSize = 0;

    for (final folder in folders) {
      final size = await getFolderSize(folder);
      folderSizes[folder] = size;
      totalSize += size;
    }

    return CacheStats(
      folderCount: folders.length,
      folderSizes: folderSizes,
      totalSize: totalSize,
    );
  }

  /// Format bytes to a human-readable format
  static String formatBytes(int bytes, {int decimals = 2}) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(decimals)} ${suffixes[i]}';
  }
}
