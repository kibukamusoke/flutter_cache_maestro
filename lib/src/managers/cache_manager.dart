import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_maestro/src/models/cache_entry.dart';
import 'package:flutter_cache_maestro/src/models/cache_exception.dart';
import 'package:flutter_cache_maestro/src/utils/file_utils.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

// Manages the caching of files fetched from URLs.
//
// Each file is stored as `<sha256(key)><ext>` with a JSON
// `<sha256(key)>.metadata` next to it, where key is the cache key or URL. The
// metadata files are the source of truth; an in-memory index built from them
// on first use serves stats, tags and size-based eviction.
//
// The TTL decides when a file is *refreshed* (with a conditional request when
// the server sent an ETag or Last-Modified); an expired file is still served
// whenever a new copy can't be downloaded, so an offline device keeps working.
// Cleanup removes files that haven't been *used* for longer than the TTL, and
// a size limit evicts the least recently used. Pinned files are kept.
//
// The cache lives outside the device backup: Application Support excluded
// from iCloud backup on iOS, `no_backup` on Android.
class CacheManager {
  static final CacheManager _instance = CacheManager._internal();
  factory CacheManager() => _instance;
  CacheManager._internal();

  static const MethodChannel _channel = MethodChannel('flutter_cache_maestro');
  static const String _metadataSuffix = '.metadata';
  static const String _partSuffix = '.part';
  static const String _tmpSuffix = '.tmp';
  static const int _tempFileMaxAge = 86400; // stale .part/.tmp files: 1 day
  static const int _evictionGrace = 60; // never evict files used this recently

  final String _baseFolderName = 'cache_maestro';
  final Map<String, Future<File>> _inFlight = {};
  int _defaultTTL = 86400; // Default TTL: 1 day in seconds
  bool _redownloadEnabled = false;
  int? _maxCacheSize;
  bool _limitOverridesPins = false;
  Duration _connectTimeout = const Duration(seconds: 20);
  Duration _idleTimeout = const Duration(seconds: 30);
  http.Client _client = http.Client();
  Directory? _baseDirectoryOverride;
  Future<Directory>? _baseDirectory;
  Timer? _cleanupTimer;
  Future<void>? _cleanupRunning;
  Future<void>? _trimRunning;
  int _generation = 0;

  // In-memory index: '<folder>/<key>' -> entry. Null until first needed.
  Map<String, CacheEntry>? _index;
  Future<void>? _indexBuild;
  // Changes made while the index is being built, applied when it finishes.
  Map<String, CacheEntry?>? _indexJournal;

  /// Increments whenever cached files are removed (clear, cleanup or
  /// eviction), so in-memory lookups (e.g. in [CachedMediaWidget]) know to
  /// look again.
  int get cacheGeneration => _generation;

  // Initialize the cache maestro with custom settings
  Future<void> init({
    int? defaultTTL,
    bool? redownloadEnabled,
    int? maxCacheSize,
    bool? limitOverridesPins,
    Duration? connectTimeout,
    Duration? idleTimeout,
  }) async {
    if (defaultTTL != null) {
      _defaultTTL = defaultTTL;
    }

    if (redownloadEnabled != null) {
      _redownloadEnabled = redownloadEnabled;
    }

    if (maxCacheSize != null) {
      _maxCacheSize = maxCacheSize;
    }

    if (limitOverridesPins != null) {
      _limitOverridesPins = limitOverridesPins;
    }

    if (connectTimeout != null) {
      _connectTimeout = connectTimeout;
    }

    if (idleTimeout != null) {
      _idleTimeout = idleTimeout;
    }

    // Resolves (and if needed moves) the cache directory.
    await _getBaseDirectory();

    // Start cleanup task
    _startCleanupTask();
  }

  /// Replaces the HTTP client and/or cache location. For tests only.
  @visibleForTesting
  void debugOverride({http.Client? client, Directory? baseDirectory}) {
    if (client != null) _client = client;
    if (baseDirectory != null) {
      _baseDirectoryOverride = baseDirectory;
      _baseDirectory = null;
    }
  }

  /// Restores default settings and forgets in-memory state. For tests only.
  @visibleForTesting
  void debugReset() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _inFlight.clear();
    _defaultTTL = 86400;
    _redownloadEnabled = false;
    _maxCacheSize = null;
    _limitOverridesPins = false;
    _connectTimeout = const Duration(seconds: 20);
    _idleTimeout = const Duration(seconds: 30);
    _client = http.Client();
    _baseDirectoryOverride = null;
    _baseDirectory = null;
    _index = null;
    _indexBuild = null;
    _indexJournal = null;
  }

  // ---------------------------------------------------------------------------
  // Storage location
  // ---------------------------------------------------------------------------

  // Get the base directory for cache storage
  Future<Directory> _getBaseDirectory() {
    final override = _baseDirectoryOverride;
    if (override != null) {
      return Future.value(Directory(path.join(override.path, _baseFolderName)));
    }
    return _baseDirectory ??= _resolveBaseDirectory();
  }

  Future<Directory> _resolveBaseDirectory() async {
    final support = await getApplicationSupportDirectory();
    var parent = support;
    if (Platform.isAndroid) {
      // Context.getNoBackupFilesDir() is `<dataDir>/no_backup`, next to
      // getFilesDir() (`<dataDir>/files`), which path_provider returns here.
      final noBackup =
          Directory(path.join(path.dirname(support.path), 'no_backup'));
      try {
        await noBackup.create(recursive: true);
        parent = noBackup;
      } on FileSystemException {
        // Keep Application Support.
      }
    }

    var base = Directory(path.join(parent.path, _baseFolderName));

    // Before 0.2.0 the cache lived in the documents directory, which is
    // backed up (and visible in the Files app on iOS if file sharing is on).
    try {
      final documents = await getApplicationDocumentsDirectory();
      final legacy = Directory(path.join(documents.path, _baseFolderName));
      if (legacy.path != base.path && await legacy.exists()) {
        base = await moveCacheDirectory(legacy, base);
      }
    } on MissingPlatformDirectoryException {
      // No documents directory on this platform: nothing to move.
    }

    await base.create(recursive: true);
    if (Platform.isIOS) {
      try {
        await _channel
            .invokeMethod<bool>('excludeFromBackup', {'path': base.path});
      } on PlatformException catch (e) {
        debugPrint('flutter_cache_maestro: excludeFromBackup failed: $e');
      } on MissingPluginException {
        // Running without the native side (e.g. some test setups).
      }
    }
    return base;
  }

  /// Moves an old cache directory [from] to [to] and returns the directory to
  /// use. Renames in one step when [to] doesn't exist yet; otherwise moves
  /// the folders [to] doesn't have and drops the rest. If [from] can't be
  /// moved at all, keeps using it so offline files aren't lost.
  @visibleForTesting
  static Future<Directory> moveCacheDirectory(
      Directory from, Directory to) async {
    if (!await to.exists()) {
      try {
        await to.parent.create(recursive: true);
        return await from.rename(to.path);
      } on FileSystemException {
        return from;
      }
    }

    await for (final child in from.list()) {
      final destination = path.join(to.path, path.basename(child.path));
      if (await FileSystemEntity.type(destination) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      try {
        await child.rename(destination);
      } on FileSystemException {
        // Left behind; deleted below.
      }
    }
    try {
      await from.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
    return to;
  }

  // Get directory for a specific folder (does not create it)
  Future<Directory> _getFolderDirectory(String folderName) async {
    final baseDir = await _getBaseDirectory();
    final safeName = FileUtils.sanitizeFolderName(folderName);
    return Directory(path.join(baseDir.path, safeName));
  }

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // ---------------------------------------------------------------------------
  // Fetching
  // ---------------------------------------------------------------------------

  // Get file from cache or download it.
  //
  // Returns the cached file while it is younger than [ttl] (default TTL if
  // null). Otherwise downloads a new copy, and if that fails (offline, server
  // error, timeout) returns the expired copy instead of failing. Only throws
  // when there is no cached copy at all.
  //
  // [cacheKey] identifies the file instead of the URL, for URLs that change
  // while the file doesn't (e.g. signed URLs). [tags] are added to the file's
  // tags. [pin] pins (true) or unpins (false) the file; null leaves it.
  //
  // Concurrent calls for the same file share one download.
  Future<File> getFile(
    String url, {
    String? folderName,
    int? ttl,
    Map<String, String>? headers,
    String? cacheKey,
    Set<String>? tags,
    bool? pin,
  }) {
    final folder = FileUtils.sanitizeFolderName(folderName ?? 'default');
    final requestKey = '$folder|${cacheKey ?? url}';
    final existing = _inFlight[requestKey];
    if (existing != null) return existing;

    final future = _getFile(
      url,
      folder,
      ttl,
      headers,
      cacheKey,
      tags ?? const {},
      pin,
    );
    _inFlight[requestKey] = future;
    future.whenComplete(() => _inFlight.remove(requestKey)).ignore();
    return future;
  }

  Future<File> _getFile(
    String url,
    String folder,
    int? ttl,
    Map<String, String>? headers,
    String? cacheKey,
    Set<String> tags,
    bool? pin,
  ) async {
    final folderDir = await _getFolderDirectory(folder);
    final key = FileUtils.cacheKey(cacheKey ?? url);
    final id = '$folder/$key';

    var entry = await _readEntry(folderDir, key);
    if (entry == null && cacheKey == null) {
      entry = await _adoptLegacyFile(folderDir, url, key);
      if (entry != null) _indexPut(id, entry);
    }

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
      final updated = _withTagsAndPin(entry, tags, pin);
      if (!identical(updated, entry)) {
        await _writeEntry(folderDir, key, updated.touched(_nowSeconds()));
        _indexPut(id, updated.touched(_nowSeconds()));
      } else {
        _touch(folderDir, key, id, entry);
      }
      return cached;
    }

    try {
      return await _download(
        url: url,
        folderDir: folderDir,
        key: key,
        id: id,
        ttl: ttl,
        headers: headers,
        previous: cached != null ? entry : null,
        cachedFile: cached,
        tags: tags,
        pin: pin,
      );
    } catch (e) {
      // If downloading fails and we have a cached version, return it
      if (cached != null && entry != null) {
        _touch(folderDir, key, id, entry);
        return cached;
      }
      rethrow;
    }
  }

  // Applies requested tags and pin state; returns [entry] itself if nothing
  // changes.
  static CacheEntry _withTagsAndPin(
      CacheEntry entry, Set<String> tags, bool? pin) {
    final addsTags = !entry.tags.containsAll(tags);
    final changesPin = pin != null && pin != entry.pinned;
    if (!addsTags && !changesPin) return entry;
    return entry.copyWith(
      tags: addsTags ? {...entry.tags, ...tags} : null,
      pinned: pin,
    );
  }

  // Streams the response to `<name>.part`, then renames it into place so a
  // killed app never leaves a truncated file that looks valid. When a cached
  // copy exists, asks the server whether it changed (ETag/Last-Modified) and
  // keeps it on 304 Not Modified.
  Future<File> _download({
    required String url,
    required Directory folderDir,
    required String key,
    required String id,
    required int? ttl,
    required Map<String, String>? headers,
    required CacheEntry? previous,
    required File? cachedFile,
    required Set<String> tags,
    required bool? pin,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    if (headers != null) request.headers.addAll(headers);
    if (previous != null && cachedFile != null) {
      final etag = previous.etag;
      final lastModified = previous.lastModified;
      if (etag != null) {
        request.headers.putIfAbsent('If-None-Match', () => etag);
      }
      if (lastModified != null) {
        request.headers.putIfAbsent('If-Modified-Since', () => lastModified);
      }
    }

    final response = await _client.send(request).timeout(_connectTimeout);

    if (response.statusCode == 304 && previous != null && cachedFile != null) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      final now = _nowSeconds();
      final confirmed = _withTagsAndPin(previous, tags, pin).copyWith(
        url: url,
        fetchedAt: now,
        lastAccessedAt: now,
        etag: response.headers['etag'],
        lastModified: response.headers['last-modified'],
      );
      await _writeEntry(folderDir, key, confirmed);
      _indexPut(id, confirmed);
      return cachedFile;
    }

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

    final file = await partFile.rename(path.join(folderDir.path, filename));

    final now = _nowSeconds();
    final entry = CacheEntry(
      url: url,
      file: filename,
      fetchedAt: now,
      lastAccessedAt: now,
      ttl: ttl,
      size: written,
      contentType: contentType,
      etag: response.headers['etag'],
      lastModified: response.headers['last-modified'],
      pinned: pin ?? previous?.pinned ?? false,
      tags: {...?previous?.tags, ...tags},
    );
    await _writeEntry(folderDir, key, entry);
    _indexPut(id, entry);

    // The extension can change (e.g. the server now sends a Content-Type).
    if (previous != null && previous.file != filename) {
      await _deleteQuietly(File(path.join(folderDir.path, previous.file)));
    }

    if (_maxCacheSize != null) {
      unawaited(trimToMaxSize().catchError((_) {}));
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

  // Records that a file was used: always in memory (for eviction order), on
  // disk at most every few hours (for cleanup after a restart).
  void _touch(Directory folderDir, String key, String id, CacheEntry entry) {
    final now = _nowSeconds();
    final touched = entry.touched(now);
    if (_index?.containsKey(id) ?? false) _index![id] = touched;
    final interval = _defaultTTL ~/ 4 < 86400 ? _defaultTTL ~/ 4 : 86400;
    if (now - entry.lastAccessedAt < interval) return;
    unawaited(_writeEntry(folderDir, key, touched).catchError((_) {}));
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

  // ---------------------------------------------------------------------------
  // Index
  // ---------------------------------------------------------------------------

  Future<Map<String, CacheEntry>> _loadIndex() async {
    final index = _index;
    if (index != null) return index;
    await (_indexBuild ??= _buildIndex());
    return _index!;
  }

  Future<void> _buildIndex() async {
    _indexJournal = {};
    final map = <String, CacheEntry>{};
    final baseDir = await _getBaseDirectory();
    if (await baseDir.exists()) {
      await for (final entity in baseDir.list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith(_metadataSuffix)) {
          continue;
        }
        final folder =
            path.relative(path.dirname(entity.path), from: baseDir.path);
        if (folder == '.') continue;
        try {
          var entry = CacheEntry.tryDecode(await entity.readAsString());
          if (entry == null) continue; // legacy or corrupt: not indexed
          if (entry.size == null) {
            final data = File(path.join(path.dirname(entity.path), entry.file));
            if (!await data.exists()) continue;
            entry = entry.copyWith(size: await data.length());
          }
          final key = path.basename(entity.path).substring(
              0, path.basename(entity.path).length - _metadataSuffix.length);
          map['$folder/$key'] = entry;
        } on FileSystemException {
          continue;
        }
      }
    }
    _indexJournal!.forEach((id, entry) {
      if (entry == null) {
        map.remove(id);
      } else {
        map[id] = entry;
      }
    });
    _indexJournal = null;
    _index = map;
  }

  void _indexPut(String id, CacheEntry? entry) {
    final index = _index;
    if (index != null) {
      if (entry == null) {
        index.remove(id);
      } else {
        index[id] = entry;
      }
    } else {
      _indexJournal?[id] = entry;
    }
  }

  // Waits for a running index build, so bulk removals aren't lost.
  Future<void> _settleIndex() async {
    if (_index == null && _indexBuild != null) await _indexBuild;
  }

  Future<void> _deleteEntry(Directory baseDir, String id, CacheEntry entry) {
    final slash = id.lastIndexOf('/');
    final dir = path.join(baseDir.path, id.substring(0, slash));
    final key = id.substring(slash + 1);
    _indexPut(id, null);
    return Future.wait([
      _deleteQuietly(File(path.join(dir, entry.file))),
      _deleteQuietly(File(path.join(dir, '$key$_metadataSuffix'))),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Pinning, tags and size limit
  // ---------------------------------------------------------------------------

  /// Pins or unpins a cached file. Pinned files are never removed by cleanup
  /// or the size limit; use it for files the user needs offline. Returns
  /// false if the file isn't cached.
  Future<bool> setPinned(
    String url, {
    String? folderName,
    String? cacheKey,
    required bool pinned,
  }) async {
    final folder = FileUtils.sanitizeFolderName(folderName ?? 'default');
    final folderDir = await _getFolderDirectory(folder);
    final key = FileUtils.cacheKey(cacheKey ?? url);
    final entry = await _readEntry(folderDir, key);
    if (entry == null) return false;
    if (entry.pinned != pinned) {
      final updated = entry.copyWith(pinned: pinned);
      await _writeEntry(folderDir, key, updated);
      _indexPut('$folder/$key', updated);
    }
    return true;
  }

  /// Pins or unpins every cached file with [tag], e.g. all of a farm's media
  /// when the user marks the farm "available offline". Files cached later
  /// are only pinned if requested with `pin: true`.
  Future<void> setTagPinned(String tag, {required bool pinned}) =>
      _setPinnedWhere((e) => e.tags.contains(tag), pinned);

  /// Unpins every file, or only files with [tag].
  Future<void> unpinAll({String? tag}) =>
      _setPinnedWhere((e) => tag == null || e.tags.contains(tag), false);

  Future<void> _setPinnedWhere(
      bool Function(CacheEntry entry) test, bool pinned) async {
    final index = await _loadIndex();
    final baseDir = await _getBaseDirectory();
    for (final item in index.entries.toList()) {
      final entry = item.value;
      if (entry.pinned == pinned || !test(entry)) continue;
      final slash = item.key.lastIndexOf('/');
      final dir =
          Directory(path.join(baseDir.path, item.key.substring(0, slash)));
      final updated = entry.copyWith(pinned: pinned);
      try {
        await _writeEntry(dir, item.key.substring(slash + 1), updated);
        _indexPut(item.key, updated);
      } on FileSystemException {
        // Removed meanwhile.
      }
    }
  }

  /// Total size in bytes of the cached files with [tag].
  Future<int> getTagSize(String tag) async {
    final index = await _loadIndex();
    return index.values
        .where((e) => e.tags.contains(tag))
        .fold<int>(0, (sum, e) => sum + (e.size ?? 0));
  }

  /// Deletes every cached file with [tag], pinned or not.
  Future<void> clearTag(String tag) async {
    final index = await _loadIndex();
    final baseDir = await _getBaseDirectory();
    final matches =
        index.entries.where((e) => e.value.tags.contains(tag)).toList();
    for (final item in matches) {
      await _deleteEntry(baseDir, item.key, item.value);
    }
    if (matches.isNotEmpty) _generation++;
  }

  /// Total size in bytes of pinned files.
  Future<int> getPinnedSize() async {
    final index = await _loadIndex();
    return index.values
        .where((e) => e.pinned)
        .fold<int>(0, (sum, e) => sum + (e.size ?? 0));
  }

  /// Sets the cache size limit in bytes, or removes it with null. When the
  /// cache grows past it, the least recently used unpinned files are removed
  /// until it is back under 90% of the limit.
  ///
  /// With [overridePins], pinned files are removed too (least recently used
  /// first) when unpinned files alone can't bring the cache under the limit,
  /// so the limit always holds. Pins then only protect against TTL cleanup.
  /// Null leaves the current setting.
  void setMaxCacheSize(int? bytes, {bool? overridePins}) {
    _maxCacheSize = bytes;
    if (overridePins != null) _limitOverridesPins = overridePins;
  }

  /// Applies the size limit now. Also runs after each download and during
  /// cleanup. Files cached by versions before 0.1.10 that haven't been opened
  /// since aren't counted.
  Future<void> trimToMaxSize() {
    return _trimRunning ??=
        _trimToMaxSize().whenComplete(() => _trimRunning = null);
  }

  Future<void> _trimToMaxSize() async {
    final maxSize = _maxCacheSize;
    if (maxSize == null) return;
    final index = await _loadIndex();
    var total = index.values.fold<int>(0, (sum, e) => sum + (e.size ?? 0));
    if (total <= maxSize) return;

    final target = maxSize * 9 ~/ 10;
    final now = _nowSeconds();
    int byLastUse(
            MapEntry<String, CacheEntry> a, MapEntry<String, CacheEntry> b) =>
        a.value.lastAccessedAt.compareTo(b.value.lastAccessedAt);
    final evictable = index.entries
        .where((e) => now - e.value.lastAccessedAt > _evictionGrace)
        .toList();
    // Unpinned files first; pinned ones only if allowed and still needed.
    final candidates = [
      ...evictable.where((e) => !e.value.pinned).toList()..sort(byLastUse),
      if (_limitOverridesPins)
        ...evictable.where((e) => e.value.pinned).toList()..sort(byLastUse),
    ];

    final baseDir = await _getBaseDirectory();
    var removed = 0;
    for (final item in candidates) {
      if (total <= target) break;
      await _deleteEntry(baseDir, item.key, item.value);
      total -= item.value.size ?? 0;
      removed++;
    }
    if (removed > 0) _generation++;
  }

  // ---------------------------------------------------------------------------
  // Folders
  // ---------------------------------------------------------------------------

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
    await _settleIndex();
    final folder = FileUtils.sanitizeFolderName(folderName);
    final folderDir = await _getFolderDirectory(folder);
    if (await folderDir.exists()) {
      await folderDir.delete(recursive: true);
    }
    _index?.removeWhere((id, _) => id.startsWith('$folder/'));
    _generation++;
  }

  // Clear all cached data
  Future<void> clearAllCache() async {
    await _settleIndex();
    final baseDir = await _getBaseDirectory();
    if (await baseDir.exists()) {
      await baseDir.delete(recursive: true);
    }
    await baseDir.create(recursive: true);
    _index?.clear();
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

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

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

  /// Deletes unpinned files that haven't been used for longer than the
  /// default TTL (or their own TTL, if longer), plus leftovers from
  /// interrupted downloads, then applies the size limit. Runs automatically
  /// after [init]; safe to call any time.
  Future<void> removeExpiredFiles() {
    return _cleanupRunning ??=
        _removeExpiredFiles().whenComplete(() => _cleanupRunning = null);
  }

  Future<void> _removeExpiredFiles() async {
    final baseDir = await _getBaseDirectory();
    if (await baseDir.exists()) {
      final removed = await _cleanDirectory(baseDir, baseDir, _nowSeconds());
      if (removed > 0) _generation++;
    }
    await trimToMaxSize();
  }

  // Cleans one directory and its subfolders. Returns the number of files
  // removed.
  Future<int> _cleanDirectory(Directory baseDir, Directory dir, int now) async {
    var removed = 0;
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is Directory) {
        removed += await _cleanDirectory(baseDir, entity, now);
      } else if (entity is File) {
        files.add(entity);
      }
    }

    final folder = path.relative(dir.path, from: baseDir.path);
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
        final maxIdle = ttl != null && ttl > _defaultTTL ? ttl : _defaultTTL;
        if (!entry.pinned && now - entry.lastAccessedAt > maxIdle) {
          final name = path.basename(metadataFile.path);
          final key = name.substring(0, name.length - _metadataSuffix.length);
          await _deleteQuietly(File(path.join(dir.path, entry.file)));
          await _deleteQuietly(metadataFile);
          _indexPut('$folder/$key', null);
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
        final modified =
            (await file.lastModified()).millisecondsSinceEpoch ~/ 1000;
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
