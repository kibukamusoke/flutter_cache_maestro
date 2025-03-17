# Flutter Cache Maestro

A Flutter plugin for efficiently caching data from various types of links such as images, videos, audio files, documents, and any downloadable content. Simplify your app's caching needs with a powerful, easy-to-use manager.

<a href="https://www.buymeacoffee.com/trevorsuna" target="_blank"><img src="https://firebasestorage.googleapis.com/v0/b/polaris-c4a50.appspot.com/o/trevorsuna%2Fbuymeabeer.png?alt=media&token=afe523cb-8699-4898-85c3-acbaf3a71031" alt="Buy Me A Coffee" style="height: 40px !important;width: 200px !important;" ></a>

## Features

- Cache files from any URL with minimal memory footprint
- Organize cached files in custom folders
- Get folder sizes and manage storage space
- Set global Time-To-Live (TTL) for automatic cache expiration
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

- Flutter 2.0.0 or higher
- Dart 2.12.0 or higher (null safety support)
- Android: minSdkVersion 16
- iOS: iOS 9.0 or higher

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
  ttl: 3600, // Override TTL for this file (1 hour)
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

## Performance Considerations

- The plugin automatically cleans up expired files in the background
- Files are stored in the application's documents directory
- Metadata is stored alongside each file to track creation time
- Cache operations run asynchronously to avoid blocking the UI thread

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
