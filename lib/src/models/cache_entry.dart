import 'dart:convert';

/// Metadata stored next to each cached file as `<key>.metadata` (JSON).
///
/// Internal: not exported from the package.
class CacheEntry {
  static const int version = 2;

  /// Source URL.
  final String url;

  /// Name of the data file in the same folder, e.g. `<sha256>.jpg`.
  final String file;

  /// When the file was last downloaded (seconds since epoch). 0 means
  /// "never confirmed", e.g. a file migrated from an older version, so it is
  /// refreshed the next time the network is available.
  final int fetchedAt;

  /// When the file was last served (seconds since epoch). Cleanup removes
  /// files that haven't been used for longer than the TTL.
  final int lastAccessedAt;

  /// TTL in seconds the file was requested with, if it differs from the
  /// default. Cleanup keeps the file at least this long.
  final int? ttl;

  final int? size;
  final String? contentType;
  final String? etag;
  final String? lastModified;

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
  });

  bool isFresh(int maxAgeSeconds, int nowSeconds) =>
      nowSeconds - fetchedAt < maxAgeSeconds;

  CacheEntry touched(int nowSeconds) => CacheEntry(
        url: url,
        file: file,
        fetchedAt: fetchedAt,
        lastAccessedAt: nowSeconds,
        ttl: ttl,
        size: size,
        contentType: contentType,
        etag: etag,
        lastModified: lastModified,
      );

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
      );
    } catch (_) {
      return null;
    }
  }
}
