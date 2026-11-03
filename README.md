# Flutter Cache Maestro

A Flutter plugin for efficiently caching data from various types of links such as images, videos, audio files, documents, and any downloadable content. Simplify your app's caching needs with a powerful, easy-to-use manager.

<a href="https://www.buymeacoffee.com/trevorsuna" target="_blank"><img src="https://firebasestorage.googleapis.com/v0/b/polaris-c4a50.appspot.com/o/trevorsuna%2Fbuymeabeer.png?alt=media&token=afe523cb-8699-4898-85c3-acbaf3a71031" alt="Buy Me A Coffee" style="height: 40px !important;width: 200px !important;" ></a>

## Features

- Cache files from any URL with minimal memory footprint
- Organize cached files in custom folders
- Get folder sizes and manage storage space
- Offline-first: expired files are refreshed when possible and still served when the device is offline
- Set global Time-To-Live (TTL) for refreshing, and clean up files that are no longer used
- Toggle between using cached files or redownloading them
- Ready-to-use widgets for displaying cached content
- Support for various media types (images, videos, PDFs, etc.)
- Automatic cleanup of expired cache files
- Built-in error handling and fallback mechanisms

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_cache_maestro:
```

Run:

```bash
flutter pub get
```

## Requirements

- Flutter 3.22.0 or higher
- Dart 3.4.0 or higher

## Basic Usage

### Initialize Cache Manager

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize cache manager with custom settings
  await CacheManager().init(
    defaultTTL: 7 * 86400, // 7 days in seconds
    redownloadEnabled: false, // Use cached files when available
  );

  runApp(const MyApp());
}
```

### Display a Cached Image

```dart
CachedImage(
  url: 'https://example.com/image.jpg',
  folderName: 'images', // Optional folder name
  fit: BoxFit.cover,
  width: 200,
  height: 150,
)
```

### Use Any Type of Media

```dart
CachedMediaWidget(
  url: 'https://example.com/document.pdf',
  folderName: 'documents',
  builder: (context, file) {
    // Use the cached file however you need
    return YourPdfViewer(file: file);
  },
)
```

### Get File Directly

```dart
final File file = await CacheManager().getFile(
  'https://example.com/data.json',
  folderName: 'api_responses',
  ttl: 3600, // Refresh after 1 hour (override the default TTL)
  headers: {'Authorization': 'Bearer $token'}, // Optional
);

// Now use the file
final content = await file.readAsString();
```

## Cache Management

### Get Storage Statistics

```dart
final stats = await CacheManager().getCacheStats();
print('Total cache size: ${CacheManagerStats.formatBytes(stats.totalSize)}');
print('Number of folders: ${stats.folderCount}');

// Print size of each folder
stats.folderSizes.forEach((folder, size) {
  print('$folder: ${CacheManagerStats.formatBytes(size)}');
});
```

### Clear Specific Folder

```dart
await CacheManager().clearFolder('images');
```

### Clear All Cache

```dart
await CacheManager().clearAllCache();
```

### Configure Cache Settings

```dart
// Set new global TTL (time to live)
CacheManager().setDefaultTTL(30 * 86400); // 30 days

// Enable/disable redownloading (force refresh)
CacheManager().setRedownloadEnabled(true); // Always redownload files
```

## Advanced Usage

### Custom Media Widgets

You can create custom widgets for specific media types:

```dart
class CachedVideo extends StatelessWidget {
  final String url;
  final String? folderName;

  const CachedVideo({
    Key? key,
    required this.url,
    this.folderName,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CachedMediaWidget(
      url: url,
      folderName: folderName ?? 'videos',
      builder: (context, file) {
        return VideoPlayer(
          VideoPlayerController.file(file),
        );
      },
    );
  }
}
```

## Offline-first storage

### Pin what the user needs offline

```dart
// Kept until you unpin or clear it: never removed by cleanup or the size limit
await CacheManager().getFile(url, folderName: 'farm_42', pin: true);

await CacheManager().setPinned(url, folderName: 'farm_42', pinned: false);
await CacheManager().setTagPinned('farm:42', pinned: true); // a whole group
await CacheManager().unpinAll(tag: 'farm:42');
```

### Limit the cache size

```dart
await CacheManager().init(maxCacheSize: 1024 * 1024 * 1024); // 1 GB
```

Past the limit, the least recently used unpinned files are removed until the cache is under 90% of it.

```dart
// Let the limit win over pins when pinned files alone exceed it
CacheManager().setMaxCacheSize(1024 * 1024 * 1024, overridePins: true);
```

### Group files with tags

```dart
CachedImage(url: url, tags: {'farm:42', 'activity'});

final bytes = await CacheManager().getTagSize('farm:42');
await CacheManager().clearTag('farm:42'); // removes pinned files too
```

### Stable keys for changing URLs

```dart
// Signed URLs change, the file doesn't: cache it under the media id
CachedImage(url: signedUrl, cacheKey: media.id);
```

### Where files are stored

The cache is kept out of device backups: Application Support excluded from iCloud backup on iOS, and `no_backup` on Android. Versions before 0.2.0 used the documents directory; that cache is moved on first launch.

## How TTL and cleanup work

- **TTL means "refresh after".** A file younger than its TTL is served without a network request. An older file is checked with the server (`If-None-Match` / `If-Modified-Since`, so an unchanged file isn't downloaded again); if that fails (offline, timeout, server error), the old copy is served instead. `getFile` only throws a `CacheMaestroException` when there is no copy at all.
- **Cleanup removes unused files.** Unpinned files that haven't been used for longer than the default TTL (or their own TTL, if longer) are deleted. Cleanup runs 30 seconds after `init()`, then every 12 hours, or whenever you call `CacheManager().removeExpiredFiles()`.
- Concurrent requests for the same URL share one download.

## Performance Considerations

- Downloads stream straight to disk, so large videos don't fill memory
- Files are written to a temporary `.part` file and renamed when complete, so an interrupted download never leaves a broken file
- Files are named by a hash of the URL; metadata (JSON) is stored next to each file
- Timeouts are configurable: `init(connectTimeout: ..., idleTimeout: ...)`

## Example App

Check out the `example` folder for a complete sample application demonstrating all features.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_cache_maestro/flutter_cache_maestro.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CacheManager().init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Cache Maestro Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const CacheExamplePage(),
    );
  }
}

class CacheExamplePage extends StatefulWidget {
  const CacheExamplePage({Key? key}) : super(key: key);

  @override
  _CacheExamplePageState createState() => _CacheExamplePageState();
}

class _CacheExamplePageState extends State<CacheExamplePage> {
  CacheStats? _stats;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final stats = await CacheManager().getCacheStats();
    setState(() {
      _stats = stats;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cache Maestro Demo'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadStats,
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            // Image example
            const Text('Cached Image Example:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const CachedImage(
              url: 'https://picsum.photos/800/400',
              folderName: 'images',
              fit: BoxFit.cover,
              height: 200,
            ),
            const SizedBox(height: 24),

            // Stats display
            Text('Cache Statistics:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_stats != null) ...[
              Text('Total size: ${CacheManagerStats.formatBytes(_stats!.totalSize)}'),
              Text('Number of folders: ${_stats!.folderCount}'),
              const SizedBox(height: 8),
              ..._stats!.folderSizes.entries.map(
                (entry) => Text('${entry.key}: ${CacheManagerStats.formatBytes(entry.value)}'),
              ),
            ] else
              const CircularProgressIndicator(),

            const SizedBox(height: 24),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await CacheManager().clearAllCache();
          _loadStats();
        },
        tooltip: 'Clear all cache',
        child: const Icon(Icons.delete),
      ),
    );
  }
}
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/amazing-feature`)
3. Commit your Changes (`git commit -m 'Add some amazing feature'`)
4. Push to the Branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
