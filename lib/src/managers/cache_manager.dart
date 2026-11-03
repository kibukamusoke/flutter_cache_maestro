import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_maestro/src/models/cache_entry.dart';
import 'package:flutter_cache_maestro/src/models/cache_exception.dart';
import 'package:flutter_cache_maestro/src/utils/file_utils.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

// Manages the caching of files fetched from URLs.
//
// Each file is stored as `<sha256(url)><ext>` with a JSON `<sha256(url)>.metadata`
// next to it. The TTL decides when a file is *refreshed*; an expired file is
// still served whenever a new copy can't be downloaded, so an offline device
// keeps working. Cleanup only removes files that haven't been *used* for
// longer than the TTL.
class CacheManager {
  static final CacheManager _instance = CacheManager._internal();
  factory CacheManager() => _instance;
  CacheManager._internal();

  static const String _metadataSuffix = '.metadata';
  static const String _partSuffix = '.part';
  static const String _tmpSuffix = '.tmp';
  static const int _tempFileMaxAge = 86400; // stale .part/.tmp files: 1 day

  final String _baseFolderName = 'cache_maestro';
  final Map<String, Future<File>> _inFlight = {};
  int _defaultTTL = 86400; // Default TTL: 1 day in seconds
  bool _redownloadEnabled = false;
  Duration _connectTimeout = const Duration(seconds: 20);
  Duration _idleTimeout = const Duration(seconds: 30);
  http.Client _client = http.Client();
  Directory? _baseDirectoryOverride;
  Timer? _cleanupTimer;
  Future<void>? _cleanupRunning;
  int _generation = 0;

  /// Increments whenever cached files are removed (clear or cleanup), so
  /// in-memory lookups (e.g. in [CachedMediaWidget]) know to look again.
  int get cacheGeneration => _generation;

  // Initialize the cache maestro with custom settings
  Future<void> init({
    int? defaultTTL,
    bool? redownloadEnabled,
    Duration? connectTimeout,
    Duration? idleTimeout,
  }) async {
    if (defaultTTL != null) {
      _defaultTTL = defaultTTL;
    }

    if (redownloadEnabled != null) {
      _redownloadEnabled = redownloadEnabled;
    }

    if (connectTimeout != null) {
      _connectTimeout = connectTimeout;
    }

    if (idleTimeout != null) {
      _idleTimeout = idleTimeout;
    }

    // Create base directory if it doesn't exist
    final baseDir = await _getBaseDirectory();
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }

    // Start cleanup task
    _startCleanupTask();
  }

  /// Replaces the HTTP client and/or cache location. For tests only.
  @visibleForTesting
  void debugOverride({http.Client? client, Directory? baseDirectory}) {
    if (client != null) _client = client;
    if (baseDirectory != null) _baseDirectoryOverride = baseDirectory;
  }

  /// Restores default settings. For tests only.
  @visibleForTesting
  void debugReset() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _inFlight.clear();
    _defaultTTL = 86400;
    _redownloadEnabled = false;
    _connectTimeout = const Duration(seconds: 20);
    _idleTimeout = const Duration(seconds: 30);
    _client = http.Client();
    _baseDirectoryOverride = null;
  }

  // Get the base directory for cache storage
  Future<Directory> _getBaseDirectory() async {
    final override = _baseDirectoryOverride;
    if (override != null) {
      return Directory(path.join(override.path, _baseFolderName));
    }
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(path.join(appDir.path, _baseFolderName));
  }

  // Get directory for a specific folder (does not create it)
  Future<Directory> _getFolderDirectory(String folderName) async {
    final baseDir = await _getBaseDirectory();
    final safeName = FileUtils.sanitizeFolderName(folderName);
    return Directory(path.join(baseDir.path, safeName));
  }

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // Get file from cache or download it.
  //
  // Returns the cached file while it is younger than [ttl] (default TTL if
  // null). Otherwise downloads a new copy, and if that fails (offline, server
  // error, timeout) returns the expired copy instead of failing. Only throws
  // when there is no cached copy at all.
  //
  // Concurrent calls for the same URL and folder share one download.
  Future<File> getFile(
    String url, {
    String? folderName,
    int? ttl,
    Map<String, String>? headers,
  }) {
    final folder = FileUtils.sanitizeFolderName(folderName ?? 'default');
    final requestKey = '$folder|$url';
    final existing = _inFlight[requestKey];
    if (existing != null) return existing;

    final future = _getFile(url, folder, ttl, headers);
    _inFlight[requestKey] = future;
    future.whenComplete(() => _inFlight.remove(requestKey)).ignore();
    return future;
  }

  Future<File> _getFile(
    String url,
    String folder,
    int? ttl,
    Map<String, String>? headers,
  ) async {
    final folderDir = await _getFolderDirectory(folder);
    final key = FileUtils.cacheKey(url);

    var entry = await _readEntry(folderDir, key);
    entry ??= await _adoptLegacyFile(folderDir, url, key);

    File? cached;
    if (entry != null) {
      final file = File(path.join(folderDir.path, entry.file));
      if (await file.exists()) cached = file;
    }

    final maxAge = ttl ?? _defaultTTL;
    if (cached != null &&
        entry != null &&
        !_redownloadEnabled &&
        entry.isFresh(maxAge, _nowSeconds())) {
      _touch(folderDir, key, entry);
      return cached;
    }

    try {
      return await _download(url, folderDir, key, ttl, headers, entry);
    } catch (e) {
      // If downloading fails and we have a cached version, return it
      if (cached != null && entry != null) {
        _touch(folderDir, key, entry);
        return cached;
      }
      rethrow;
    }
  }

  // Streams the response to `<name>.part`, then renames it into place so a
  // killed app never leaves a truncated file that looks valid.
  Future<File> _download(
    String url,
    Directory folderDir,
    String key,
    int? ttl,
    Map<String, String>? headers,
    CacheEntry? previous,
  ) async {
    final request = http.Request('GET', Uri.parse(url));
    if (headers != null) request.headers.addAll(headers);

    final response = await _client.send(request).timeout(_connectTimeout);
    if (response.statusCode != 200) {
      // Discard the body so the connection can be reused.
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw CacheMaestroException(
        'HTTP ${response.statusCode}',
        url: url,
        statusCode: response.statusCode,
      );
    }

    final contentType = response.headers['content-type'];
    final filename = '$key${FileUtils.extensionFor(url, contentType)}';
    await folderDir.create(recursive: true);
    final partFile = File(path.join(folderDir.path, '$filename$_partSuffix'));

    var written = 0;
    final sink = partFile.openWrite();
    try {
      await for (final chunk in response.stream.timeout(_idleTimeout)) {
        sink.add(chunk);
        written += chunk.length;
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close().catchError((_) {});
      await _deleteQuietly(partFile);
      rethrow;
    }

    final expected = response.contentLength;
    if (expected != null && expected != written) {
      await _deleteQuietly(partFile);
      throw CacheMaestroException(
        'Incomplete download ($written of $expected bytes)',
        url: url,
      );
    }

    final file =
        await partFile.rename(path.join(folderDir.path, filename));

    final now = _nowSeconds();
    await _writeEntry(
      folderDir,
      key,
      CacheEntry(
        url: url,
        file: filename,
        fetchedAt: now,
        lastAccessedAt: now,
        ttl: ttl,
        size: written,
        contentType: contentType,
        etag: response.headers['etag'],
        lastModified: response.headers['last-modified'],
      ),
    );

    // The extension can change (e.g. the server now sends a Content-Type).
    if (previous != null && previous.file != filename) {
      await _deleteQuietly(File(path.join(folderDir.path, previous.file)));
    }

    return file;
  }

  Future<CacheEntry?> _readEntry(Directory folderDir, String key) async {
    final metadataFile =
        File(path.join(folderDir.path, '$key$_metadataSuffix'));
    try {
      if (!await metadataFile.exists()) return null;
      return CacheEntry.tryDecode(await metadataFile.readAsString());
    } on FileSystemException {
      return null;
    }
  }

  // Writes via a temp file and rename so metadata is never half-written.
  Future<void> _writeEntry(
      Directory folderDir, String key, CacheEntry entry) async {
    final target = path.join(folderDir.path, '$key$_metadataSuffix');
    final tmp = File('$target$_tmpSuffix');
    await tmp.writeAsString(entry.encode(), flush: true);
    await tmp.rename(target);
  }

  // Records that a file was used, at most every few hours, so cleanup keeps
  // files that are still in use.
  void _touch(Directory folderDir, String key, CacheEntry entry) {
    final now = _nowSeconds();
    final interval = _defaultTTL ~/ 4 < 86400 ? _defaultTTL ~/ 4 : 86400;
    if (now - entry.lastAccessedAt < interval) return;
    unawaited(
      _writeEntry(folderDir, key, entry.touched(now)).catchError((_) {}),
    );
  }

  // Moves a file cached by a version before 0.1.10 (named after the URL's
  // basename) to the new name, so offline users keep their files. It is
  // marked as never confirmed, so it is replaced the next time the device is
  // online: the old naming could have stored another URL's file under it.
  Future<CacheEntry?> _adoptLegacyFile(
      Directory folderDir, String url, String key) async {
    final String legacyName;
    try {
      legacyName = FileUtils.legacyFilename(url);
    } on FormatException {
      return null;
    }
    final legacyFile = File(path.join(folderDir.path, legacyName));
    try {
      if (!await legacyFile.exists()) return null;
      final filename = '$key${FileUtils.extensionFor(url)}';
      final size = await legacyFile.length();
      await legacyFile.rename(path.join(folderDir.path, filename));
      final entry = CacheEntry(
        url: url,
        file: filename,
        fetchedAt: 0,
        lastAccessedAt: _nowSeconds(),
        size: size,
      );
      await _writeEntry(folderDir, key, entry);
      await _deleteQuietly(File('${legacyFile.path}$_metadataSuffix'));
      return entry;
    } on FileSystemException {
      // Another request adopted it first, or the file disappeared.
      return null;
    }
  }

  // Get the size of a specific folder
  Future<int> getFolderSize(String folderName) async {
    final folderDir = await _getFolderDirectory(folderName);
    if (!await folderDir.exists()) return 0;
    int totalSize = 0;

    await for (final entity in folderDir.list(recursive: true)) {
      if (entity is File) {
        totalSize += await entity.length();
      }
    }

    return totalSize;
  }

  // Get all folder names
  Future<List<String>> getAllFolders() async {
    final baseDir = await _getBaseDirectory();
    final List<String> folders = [];
    if (!await baseDir.exists()) return folders;

    await for (final entity in baseDir.list()) {
      if (entity is Directory) {
        folders.add(path.basename(entity.path));
      }
    }

    return folders;
  }

  // Clear a specific folder (delete all files)
  Future<void> clearFolder(String folderName) async {
    final folderDir = await _getFolderDirectory(folderName);
    if (await folderDir.exists()) {
      await folderDir.delete(recursive: true);
    }
    _generation++;
  }

  // Clear all cached data
  Future<void> clearAllCache() async {
    final baseDir = await _getBaseDirectory();
    if (await baseDir.exists()) {
      await baseDir.delete(recursive: true);
    }
    await baseDir.create(recursive: true);
    _generation++;
  }

  // Set global TTL (time to live) for cached files
  void setDefaultTTL(int seconds) {
    _defaultTTL = seconds;
  }

  // Set whether to always redownload files or use cache
  void setRedownloadEnabled(bool enabled) {
    _redownloadEnabled = enabled;
  }

  // Runs cleanup shortly after start-up (apps rarely stay open long enough
  // for a long timer to fire), then every 12 hours while the app is open.
  void _startCleanupTask() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer(const Duration(seconds: 30), () {
      unawaited(removeExpiredFiles().catchError((_) {}));
      _cleanupTimer = Timer.periodic(
        const Duration(hours: 12),
        (_) => unawaited(removeExpiredFiles().catchError((_) {})),
      );
    });
  }

  /// Deletes files that haven't been used for longer than the default TTL
  /// (or their own TTL, if longer), plus leftovers from interrupted
  /// downloads. Runs automatically after [init]; safe to call any time.
  Future<void> removeExpiredFiles() {
    return _cleanupRunning ??=
        _removeExpiredFiles().whenComplete(() => _cleanupRunning = null);
  }

  Future<void> _removeExpiredFiles() async {
    final baseDir = await _getBaseDirectory();
    if (!await baseDir.exists()) return;
    final removed = await _cleanDirectory(baseDir, _nowSeconds());
    if (removed > 0) _generation++;
  }

  // Cleans one directory and its subfolders. Returns the number of files
  // removed.
  Future<int> _cleanDirectory(Directory dir, int now) async {
    var removed = 0;
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is Directory) {
        removed += await _cleanDirectory(entity, now);
      } else if (entity is File) {
        files.add(entity);
      }
    }

    final keep = <String>{};
    for (final metadataFile
        in files.where((f) => f.path.endsWith(_metadataSuffix))) {
      final String content;
      try {
        content = await metadataFile.readAsString();
      } on FileSystemException {
        continue;
      }

      final entry = CacheEntry.tryDecode(content);
      if (entry != null) {
        final ttl = entry.ttl;
        final maxIdle =
            ttl != null && ttl > _defaultTTL ? ttl : _defaultTTL;
        if (now - entry.lastAccessedAt > maxIdle) {
          await _deleteQuietly(File(path.join(dir.path, entry.file)));
          await _deleteQuietly(metadataFile);
          removed++;
        } else {
          keep
            ..add(path.basename(metadataFile.path))
            ..add(entry.file);
        }
        continue;
      }

      // Pre-0.1.10 metadata: a plain download timestamp next to `<file>`.
      final dataPath = metadataFile.path
          .substring(0, metadataFile.path.length - _metadataSuffix.length);
      final legacyTime = int.tryParse(content.trim());
      if (legacyTime != null && now - legacyTime <= _defaultTTL) {
        keep
          ..add(path.basename(metadataFile.path))
          ..add(path.basename(dataPath));
      } else {
        // Expired or corrupt.
        await _deleteQuietly(File(dataPath));
        await _deleteQuietly(metadataFile);
        removed++;
      }
    }

    // Files no metadata refers to: interrupted downloads, metadata lost in a
    // crash, or old-version files without metadata. Give them time before
    // deleting, in case a download is still running or they get adopted.
    for (final file in files) {
      final name = path.basename(file.path);
      if (keep.contains(name)) continue;
      if (name.endsWith(_metadataSuffix)) continue; // handled above
      final isTemp = name.endsWith(_partSuffix) || name.endsWith(_tmpSuffix);
      final maxAge = isTemp ? _tempFileMaxAge : _defaultTTL;
      try {
        final modified = (await file.lastModified()).millisecondsSinceEpoch ~/
            1000;
        if (now - modified > maxAge) {
          await file.delete();
          removed++;
        }
      } on FileSystemException {
        // Already gone.
      }
    }

    return removed;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
