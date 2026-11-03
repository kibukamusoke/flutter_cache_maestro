// Cache statistics model
class CacheStats {
  final int folderCount;
  final Map<String, int> folderSizes;
  final int totalSize;

  /// Bytes in pinned files (kept by cleanup and the size limit).
  final int pinnedSize;

  CacheStats({
    required this.folderCount,
    required this.folderSizes,
    required this.totalSize,
    this.pinnedSize = 0,
  });
}
