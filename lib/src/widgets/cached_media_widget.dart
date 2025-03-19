import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_cache_maestro/src/managers/cache_manager.dart';

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
    _fileFuture = CacheManager().getFile(
      widget.url,
      folderName: widget.folderName,
      ttl: widget.ttl,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: _fileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return widget.placeholder ??
              const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return widget.errorWidget ??
              Center(child: Text('Error: ${snapshot.error}'));
        } else if (snapshot.hasData) {
          return widget.builder(context, snapshot.data!);
        } else {
          return widget.errorWidget ??
              const Center(child: Text('File not available'));
        }
      },
    );
  }
}
