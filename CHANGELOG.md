## 0.2.0

- **The cache moved out of device backups.** iOS: Application Support,
  excluded from iCloud backup (new native iOS code). Android: `no_backup`.
  The old cache in the documents directory is moved on first launch, so
  offline files are kept.
- **Size limit:** `init(maxCacheSize: bytes)` / `setMaxCacheSize`. When the
  cache grows past it, the least recently used unpinned files are removed
  until it is under 90% of the limit. Runs after downloads and during
  cleanup, or call `trimToMaxSize()`.
- **Pinning:** `getFile(pin: true)`, `setPinned`, `setTagPinned`, `unpinAll`,
  `getPinnedSize`. Pinned files are never removed by cleanup or the size
  limit, only by an explicit clear.
- **Tags:** `getFile(tags: {'farm:123'})`, `getTagSize`, `clearTag`.
- **Cache keys:** `getFile(cacheKey: 'media-id')` identifies a file
  independently of its URL (e.g. signed URLs that change).
- **Conditional requests:** expired files are revalidated with
  `If-None-Match` / `If-Modified-Since`; a `304 Not Modified` keeps the
  cached file without downloading it again.
- `CachedMediaWidget` and `CachedImage` accept `cacheKey`, `tags` and `pin`.
- `CacheStats.pinnedSize`.
- An in-memory index (built from the metadata files on first use) serves
  tag, pin and size-limit queries.

## 0.1.10

- Cached files are now named by a SHA-256 of the URL, so URLs that share a
  filename (`a/photo.jpg`, `b/photo.jpg`) no longer overwrite each other.
  Files cached by older versions are migrated the first time they are
  requested, and refreshed once the device is online.
- Downloads stream to disk instead of loading the whole file into memory, and
  are written to a `.part` file and renamed into place, so a killed app never
  leaves a truncated file behind. Downloads shorter than `Content-Length` are
  rejected.
- The TTL now decides when a file is refreshed, not when it is deleted. An
  expired file is still served when a new copy can't be downloaded (offline,
  timeout, server error). Cleanup removes files that haven't been used for
  longer than the TTL (or the file's own TTL, if longer), including files in
  nested folders and leftovers from interrupted downloads.
- Cleanup runs 30 seconds after `init()` and then every 12 hours; calling
  `init()` again no longer starts extra timers. Run it on demand with
  `removeExpiredFiles()`.
- Concurrent `getFile` calls for the same URL share one download.
- New: `headers` on `getFile`, `CachedMediaWidget` and `CachedImage`;
  `connectTimeout` and `idleTimeout` on `init()` (defaults 20 s / 30 s).
- New: `CacheMaestroException` (with `statusCode`) when a download fails and
  nothing is cached.
- Cached files get an extension from `Content-Type` when the URL has none.
- `CachedMediaWidget` loads the new file when its URL changes, forgets failed
  loads so the next build retries, keeps at most 200 lookups in memory, and
  stops serving files removed by a clear or cleanup. The default error widget
  is an icon instead of the raw error text.
- Folder names can no longer point outside the cache directory (`..`).
- `getFolderSize` and `clearFolder` no longer create the folder.
- Corrupt metadata no longer makes `getFile` throw.
- `FileUtils.generateFilename` is deprecated.
- Requires Dart 3.4 / Flutter 3.22 (already required by `http ^1.3.0`).

## 0.1.9

- Updated dependency versions to latest compatible versions
- Updated path_provider to ^2.1.5
- Updated path to ^1.9.1
- Updated crypto to ^3.0.6

## 0.1.8

- Added a key to futurebuilder to maintain the state of the widget
- fixed a bug in stats extension where static calling was failing

## 0.1.5

- Updated http package version to the latest version 1.3.0

## 0.1.1

- Initial release of Flutter Cache Maestro
- Core features:
  - File caching with customizable TTL (Time-To-Live)
  - Automatic cache cleanup
  - Folder organization for different media types
  - Built-in widgets for displaying cached media
  - Storage statistics and management
- Supports caching of images, videos, audio files, PDFs, and other file types
- Implements singleton pattern for efficient cache management
- Full null safety support

## 0.0.1

- Initial development version (pre-release)
