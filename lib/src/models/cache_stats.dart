// Cache statistics model
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
