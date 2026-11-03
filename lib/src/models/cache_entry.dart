import 'dart:convert';

/// Metadata stored next to each cached file as `<key>.metadata` (JSON).
///
/// The `.metadata` files are the source of truth; [CacheManager] also keeps
/// them in an in-memory index for stats, tags and size-based eviction.
///
/// Internal: not exported from the package.
class CacheEntry {
  static const int version = 2;

  /// URL the file was last downloaded from.
  final String url;

  /// Name of the data file in the same folder, e.g. `<sha256>.jpg`.
  final String file;

  /// When the file was last downloaded or confirmed unchanged by the server
  /// (seconds since epoch). 0 means "never confirmed", e.g. a file migrated
  /// from an older version, so it is refreshed when the network is available.
  final int fetchedAt;

  /// When the file was last served (seconds since epoch). Cleanup removes
  /// files that haven't been used for longer than the TTL, and size-based
  /// eviction removes the least recently used first.
  final int lastAccessedAt;

  /// TTL in seconds the file was requested with, if any. Cleanup keeps the
  /// file at least this long.
  final int? ttl;

  final int? size;
  final String? contentType;
  final String? etag;
  final String? lastModified;

  /// Pinned files are never removed by cleanup or size-based eviction, only
  /// by an explicit clear.
  final bool pinned;

  /// Caller-defined labels, e.g. `farm:123`, for sizing and clearing groups.
  final Set<String> tags;

  const CacheEntry({
    required this.url,
    required this.file,
    required this.fetchedAt,
    required this.lastAccessedAt,
    this.ttl,
    this.size,
    this.contentType,
    this.etag,
    this.lastModified,
    this.pinned = false,
    this.tags = const {},
  });

  bool isFresh(int maxAgeSeconds, int nowSeconds) =>
      nowSeconds - fetchedAt < maxAgeSeconds;

  CacheEntry copyWith({
    String? url,
    int? fetchedAt,
    int? lastAccessedAt,
    int? size,
    String? etag,
    String? lastModified,
    bool? pinned,
    Set<String>? tags,
  }) =>
      CacheEntry(
        url: url ?? this.url,
        file: file,
        fetchedAt: fetchedAt ?? this.fetchedAt,
        lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
        ttl: ttl,
        size: size ?? this.size,
        contentType: contentType,
        etag: etag ?? this.etag,
        lastModified: lastModified ?? this.lastModified,
        pinned: pinned ?? this.pinned,
        tags: tags ?? this.tags,
      );

  CacheEntry touched(int nowSeconds) => copyWith(lastAccessedAt: nowSeconds);

  String encode() => jsonEncode({
        'v': version,
        'url': url,
        'file': file,
        'fetchedAt': fetchedAt,
        'lastAccessedAt': lastAccessedAt,
        if (ttl != null) 'ttl': ttl,
        if (size != null) 'size': size,
        if (contentType != null) 'contentType': contentType,
        if (etag != null) 'etag': etag,
        if (lastModified != null) 'lastModified': lastModified,
        if (pinned) 'pinned': true,
        if (tags.isNotEmpty) 'tags': tags.toList()..sort(),
      });

  /// Parses a metadata file, or returns null if it is not a valid v2 entry
  /// (corrupt, or the plain-timestamp format used before 0.1.10).
  static CacheEntry? tryDecode(String source) {
    try {
      final json = jsonDecode(source);
      if (json is! Map<String, dynamic>) return null;
      final url = json['url'];
      final file = json['file'];
      final fetchedAt = json['fetchedAt'];
      final lastAccessedAt = json['lastAccessedAt'];
      if (url is! String ||
          file is! String ||
          fetchedAt is! int ||
          lastAccessedAt is! int) {
        return null;
      }
      final tags = json['tags'];
      return CacheEntry(
        url: url,
        file: file,
        fetchedAt: fetchedAt,
        lastAccessedAt: lastAccessedAt,
        ttl: json['ttl'] as int?,
        size: json['size'] as int?,
        contentType: json['contentType'] as String?,
        etag: json['etag'] as String?,
        lastModified: json['lastModified'] as String?,
        pinned: json['pinned'] == true,
        tags: tags is List ? tags.whereType<String>().toSet() : const {},
      );
    } catch (_) {
      return null;
    }
  }
}
