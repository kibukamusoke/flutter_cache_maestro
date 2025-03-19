import 'package:flutter/material.dart';
import 'package:flutter_cache_maestro/src/widgets/cached_media_widget.dart';

// Convenience widget for cached images
class CachedImage extends StatelessWidget {
  // URL of the image to cache and display
  final String url;

  // Optional folder name for organizing cached files
  final String? folderName;

  // Optional time-to-live in seconds
  final int? ttl;

  // Optional BoxFit for the image
  final BoxFit? fit;

  // Optional width for the image
  final double? width;

  // Optional height for the image
  final double? height;

  // Optional placeholder widget to show while loading
  final Widget? placeholder;

  // Optional widget to show when an error occurs
  final Widget? errorWidget;

  const CachedImage({
    Key? key,
    required this.url,
    this.folderName,
    this.ttl,
    this.fit,
    this.width,
    this.height,
    this.placeholder,
    this.errorWidget,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CachedMediaWidget(
      url: url,
      folderName: folderName,
      ttl: ttl,
      placeholder: placeholder,
      errorWidget: errorWidget,
      builder: (context, file) {
        return Image.file(
          file,
          fit: fit,
          width: width,
          height: height,
        );
      },
    );
  }
}
