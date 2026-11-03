/// Thrown when a file can't be downloaded and there is no cached copy to
/// fall back to.
class CacheMaestroException implements Exception {
  /// What went wrong, e.g. `HTTP 404` or `Incomplete download`.
  final String message;

  /// The URL that was requested.
  final String url;

  /// HTTP status code, when the server answered with something other than 200.
  final int? statusCode;

  const CacheMaestroException(this.message, {required this.url, this.statusCode});

  @override
  String toString() => 'CacheMaestroException: $message ($url)';
}
