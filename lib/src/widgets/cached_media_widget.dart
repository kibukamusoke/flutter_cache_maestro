import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_maestro/src/managers/cache_manager.dart';

// Remembers recent lookups so rebuilds and Hero transitions don't flash the
// placeholder. Bounded (least recently used first out), forgets failures so
// the next build retries, and is invalidated when the cache is cleared.
const int _memoLimit = 200;
final LinkedHashMap<String, _MemoEntry> _memo = LinkedHashMap();

class _MemoEntry {
  _MemoEntry(this.future, this.generation);

  final Future<File> future;
  final int generation;
  File? file;
}

_MemoEntry _lookup(String key, Future<File> Function() load) {
  final generation = CacheManager().cacheGeneration;
  var entry = _memo.remove(key);
  if (entry != null) {
    final file = entry.file;
    final stale = entry.generation != generation ||
        (file != null && !file.existsSync());
    if (stale) entry = null;
  }

  if (entry == null) {
    final created = _MemoEntry(load(), generation);
    created.future.then<void>(
      (file) {
        created.file = file;
      },
      onError: (Object _) {
        if (identical(_memo[key], created)) _memo.remove(key);
      },
    );
    entry = created;
  }

  _memo[key] = entry;
  while (_memo.length > _memoLimit) {
    _memo.remove(_memo.keys.first);
  }
  return entry;
}

// Widget to display cached media
class CachedMediaWidget extends StatefulWidget {
  // URL of the media to cache and display
  final String url;

  // Optional folder name for organizing cached files
  final String? folderName;

  // Optional time-to-live in seconds
  final int? ttl;

  // Optional HTTP headers sent when downloading (e.g. Authorization)
  final Map<String, String>? headers;

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
    this.headers,
    required this.builder,
    this.placeholder,
    this.errorWidget,
  }) : super(key: key);

  @override
  CachedMediaWidgetState createState() => CachedMediaWidgetState();
}

class CachedMediaWidgetState extends State<CachedMediaWidget> {
  late _MemoEntry _entry;

  @override
  void initState() {
    super.initState();
    _entry = _resolve();
  }

  @override
  void didUpdateWidget(CachedMediaWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Lists reuse this state for different items; load the new URL.
    if (oldWidget.url != widget.url ||
        oldWidget.folderName != widget.folderName ||
        oldWidget.ttl != widget.ttl) {
      _entry = _resolve();
    }
  }

  _MemoEntry _resolve() {
    final cacheKey =
        '${widget.url}|${widget.folderName ?? "default"}|${widget.ttl ?? 0}';
    return _lookup(
      cacheKey,
      () => CacheManager().getFile(
        widget.url,
        folderName: widget.folderName,
        ttl: widget.ttl,
        headers: widget.headers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Use a StaticFutureBuilder that doesn't rebuild during Hero transitions
    return HeroMode(
      enabled: false, // Disable Hero animations for the FutureBuilder
      child: FutureBuilder<File>(
        key: ObjectKey(_entry),
        future: _entry.future,
        initialData: _entry.file,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            // Only apply Hero animations to the actual content, not the loading states
            return widget.builder(context, snapshot.data!);
          } else if (snapshot.hasError) {
            return widget.errorWidget ??
                const Center(child: Icon(Icons.broken_image_outlined));
          } else if (snapshot.connectionState == ConnectionState.waiting) {
            return widget.placeholder ??
                const Center(child: CircularProgressIndicator());
          } else {
            return widget.errorWidget ??
                const Center(child: Icon(Icons.broken_image_outlined));
          }
        },
      ),
    );
  }
}
