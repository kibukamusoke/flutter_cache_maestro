import 'package:flutter_cache_maestro/src/managers/cache_manager.dart';
import 'package:flutter_cache_maestro/src/models/cache_stats.dart';
import 'package:flutter_cache_maestro/src/utils/file_utils.dart';

// Class for cache statistics utilities
class CacheManagerStats {
  // Static format bytes method
  static String formatBytes(int bytes, {int decimals = 2}) {
    return FileUtils.formatBytes(bytes, decimals: decimals);
  }
}

// Extension for getting cache statistics
extension CacheManagerExtension on CacheManager {
  // Get statistics about the cache
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
}
