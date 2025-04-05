import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_cache_maestro/src/managers/cache_manager.dart';

// Global file cache to persist across widget rebuilds
final Map<String, Future<File>> _globalFileCache = {};

// Widget to display cached media
class CachedMediaWidget extends StatefulWidget {
  // URL of the media to cache and display
  final String url;

  // Optional folder name for organizing cached files
  final String? folderName;

  // Optional time-to-live in seconds
  final int? ttl;

  // Builder function to create widget from cached file
  final Widget Function(BuildContext, File) builder;

  // Optional placeholder widget to show while loading
  final Widget? placeholder;

  // Optional widget to show when an error occurs
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
  CachedMediaWidgetState createState() => CachedMediaWidgetState();
}

class CachedMediaWidgetState extends State<CachedMediaWidget> {
  late Future<File> _fileFuture;

  @override
  void initState() {
    super.initState();

    // Create a unique key for this file request
    final cacheKey =
        '${widget.url}|${widget.folderName ?? "default"}|${widget.ttl ?? 0}';

    // Check if we already have this file loading or loaded
    if (!_globalFileCache.containsKey(cacheKey)) {
      // If not, start loading and store in global cache
      _globalFileCache[cacheKey] = CacheManager().getFile(
        widget.url,
        folderName: widget.folderName,
        ttl: widget.ttl,
      );
    }

    // Get the future from the global cache
    _fileFuture = _globalFileCache[cacheKey]!;
  }

  @override
  Widget build(BuildContext context) {
    // Use a StaticFutureBuilder that doesn't rebuild during Hero transitions
    return HeroMode(
      enabled: false, // Disable Hero animations for the FutureBuilder
      child: FutureBuilder<File>(
        key: ValueKey(widget.url),
        future: _fileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return widget.placeholder ??
                const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return widget.errorWidget ??
                Center(child: Text('Error: ${snapshot.error}'));
          } else if (snapshot.hasData) {
            // Only apply Hero animations to the actual content, not the loading states
            return widget.builder(context, snapshot.data!);
          } else {
            return widget.errorWidget ??
                const Center(child: Text('File not available'));
          }
        },
      ),
    );
  }
}
