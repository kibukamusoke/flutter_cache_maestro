import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_maestro/flutter_cache_maestro.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  late Directory tempDir;
  late Directory cacheDir;
  late List<http.BaseRequest> requests;

  final manager = CacheManager();

  // Serves `body:<url path>` for every URL unless [handler] says otherwise.
  void useServer([Future<http.Response> Function(http.Request)? handler]) {
    manager.debugOverride(
      client: MockClient((request) async {
        requests.add(request);
        if (handler != null) return handler(request);
        return http.Response('body:${request.url.path}', 200);
      }),
    );
  }

  void useOffline() {
    manager.debugOverride(
      client: MockClient((request) async {
        requests.add(request);
        throw const SocketException('offline');
      }),
    );
  }

  void writeEntry(String folder, String url, String content,
      {required int fetchedAt,
      required int lastAccessedAt,
      int? ttl,
      bool pinned = false,
      List<String> tags = const []}) {
    final key = FileUtils.cacheKey(url);
    final dir = Directory(path.join(cacheDir.path, folder))
      ..createSync(recursive: true);
    File(path.join(dir.path, '$key.jpg')).writeAsStringSync(content);
    File(path.join(dir.path, '$key.metadata')).writeAsStringSync(jsonEncode({
      'v': 2,
      'url': url,
      'file': '$key.jpg',
      'fetchedAt': fetchedAt,
      'lastAccessedAt': lastAccessedAt,
      if (ttl != null) 'ttl': ttl,
      'size': content.length,
      if (pinned) 'pinned': true,
      if (tags.isNotEmpty) 'tags': tags,
    }));
  }

  bool isCached(String folder, String url) => File(path.join(
          cacheDir.path, folder, '${FileUtils.cacheKey(url)}.jpg'))
      .existsSync();

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('cache_maestro_test');
    cacheDir = Directory(path.join(tempDir.path, 'cache_maestro'));
    requests = [];
    manager.debugReset();
    manager.debugOverride(baseDirectory: tempDir);
    useServer();
  });

  tearDown(() {
    manager.debugReset();
    tempDir.deleteSync(recursive: true);
  });

  test('singleton instance', () {
    expect(identical(CacheManager(), CacheManager()), isTrue);
  });

  group('getFile', () {
    test('URLs sharing a basename do not overwrite each other', () async {
      final a = await manager.getFile('https://cdn.test/a/photo.jpg',
          folderName: 'images');
      final b = await manager.getFile('https://cdn.test/b/photo.jpg',
          folderName: 'images');

      expect(a.path, isNot(b.path));
      expect(await a.readAsString(), 'body:/a/photo.jpg');
      expect(await b.readAsString(), 'body:/b/photo.jpg');
    });

    test('serves a fresh file without a request', () async {
      const url = 'https://cdn.test/x.jpg';
      await manager.getFile(url);
      await manager.getFile(url);
      expect(requests, hasLength(1));
    });

    test('serves the expired copy when the download fails', () async {
      const url = 'https://cdn.test/x.jpg';
      writeEntry('default', url, 'old',
          fetchedAt: _now() - 1000, lastAccessedAt: _now());
      useOffline();

      final file = await manager.getFile(url, ttl: 10);

      expect(requests, hasLength(1));
      expect(await file.readAsString(), 'old');
    });

    test('replaces an expired copy when online', () async {
      const url = 'https://cdn.test/x.jpg';
      writeEntry('default', url, 'old',
          fetchedAt: _now() - 1000, lastAccessedAt: _now());

      final file = await manager.getFile(url, ttl: 10);

      expect(await file.readAsString(), 'body:/x.jpg');
    });

    test('throws CacheMaestroException with status when nothing cached',
        () async {
      useServer((_) async => http.Response('nope', 404));

      await expectLater(
        manager.getFile('https://cdn.test/missing.jpg'),
        throwsA(isA<CacheMaestroException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('concurrent calls share one download', () async {
      const url = 'https://cdn.test/x.jpg';
      final results = await Future.wait([
        manager.getFile(url),
        manager.getFile(url),
        manager.getFile(url),
      ]);
      expect(requests, hasLength(1));
      expect(results.map((f) => f.path).toSet(), hasLength(1));
    });

    test('an interrupted download leaves no file behind', () async {
      manager.debugOverride(
        client: MockClient.streaming((request, _) async {
          final controller = StreamController<List<int>>();
          controller.add(utf8.encode('partial'));
          controller.addError(const SocketException('connection reset'));
          unawaited(controller.close());
          return http.StreamedResponse(controller.stream, 200);
        }),
      );

      await expectLater(
          manager.getFile('https://cdn.test/x.jpg'), throwsA(anything));

      final leftovers = cacheDir
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => path.basename(f.path));
      expect(leftovers, isEmpty);
    });

    test('rejects a download shorter than Content-Length', () async {
      manager.debugOverride(
        client: MockClient.streaming((request, _) async {
          return http.StreamedResponse(
            Stream.value(utf8.encode('short')),
            200,
            contentLength: 100,
          );
        }),
      );

      await expectLater(
        manager.getFile('https://cdn.test/x.jpg'),
        throwsA(isA<CacheMaestroException>()),
      );
    });

    test('corrupt metadata triggers a re-download instead of a crash',
        () async {
      const url = 'https://cdn.test/x.jpg';
      final key = FileUtils.cacheKey(url);
      final dir = Directory(path.join(cacheDir.path, 'default'))
        ..createSync(recursive: true);
      File(path.join(dir.path, '$key.jpg')).writeAsStringSync('old');
      File(path.join(dir.path, '$key.metadata')).writeAsStringSync('garbage');

      final file = await manager.getFile(url);

      expect(await file.readAsString(), 'body:/x.jpg');
    });

    test('adds an extension from Content-Type when the URL has none',
        () async {
      useServer((_) async => http.Response('mp4', 200,
          headers: {'content-type': 'video/mp4; charset=binary'}));

      final file = await manager.getFile('https://cdn.test/media/123');

      expect(path.extension(file.path), '.mp4');
    });

    test('sends custom headers', () async {
      await manager.getFile('https://cdn.test/x.jpg',
          headers: {'Authorization': 'Bearer t'});
      expect(requests.single.headers['Authorization'], 'Bearer t');
    });

    test('folder names cannot escape the cache directory', () async {
      final file = await manager.getFile('https://cdn.test/x.jpg',
          folderName: '../../evil');
      expect(path.isWithin(cacheDir.path, file.path), isTrue);
    });

    test('adopts a file cached by an older version while offline', () async {
      const url = 'https://cdn.test/a/photo.jpg';
      final dir = Directory(path.join(cacheDir.path, 'images'))
        ..createSync(recursive: true);
      File(path.join(dir.path, 'photo.jpg')).writeAsStringSync('legacy');
      File(path.join(dir.path, 'photo.jpg.metadata'))
          .writeAsStringSync('${_now()}');
      useOffline();

      final file = await manager.getFile(url, folderName: 'images');

      expect(await file.readAsString(), 'legacy');
      expect(File(path.join(dir.path, 'photo.jpg')).existsSync(), isFalse);
      expect(File(path.join(dir.path, 'photo.jpg.metadata')).existsSync(),
          isFalse);

      // Once online, the adopted copy is refreshed.
      useServer();
      final refreshed = await manager.getFile(url, folderName: 'images');
      expect(await refreshed.readAsString(), 'body:/a/photo.jpg');
    });
  });

  group('removeExpiredFiles', () {
    test('removes files unused for longer than the TTL, keeps recent ones',
        () async {
      manager.setDefaultTTL(100);
      const usedUrl = 'https://cdn.test/used.jpg';
      const unusedUrl = 'https://cdn.test/unused.jpg';
      const longTtlUrl = 'https://cdn.test/long.jpg';
      // Downloaded long ago but used recently: kept.
      writeEntry('images', usedUrl, 'u',
          fetchedAt: _now() - 10000, lastAccessedAt: _now() - 10);
      writeEntry('images', unusedUrl, 'x',
          fetchedAt: _now() - 10000, lastAccessedAt: _now() - 1000);
      writeEntry('images', longTtlUrl, 'l',
          fetchedAt: _now() - 10000,
          lastAccessedAt: _now() - 1000,
          ttl: 5000);

      await manager.removeExpiredFiles();

      final dir = path.join(cacheDir.path, 'images');
      bool exists(String url) =>
          File(path.join(dir, '${FileUtils.cacheKey(url)}.jpg')).existsSync();
      expect(exists(usedUrl), isTrue);
      expect(exists(unusedUrl), isFalse);
      expect(exists(longTtlUrl), isTrue);
    });

    test('cleans nested folders, stale partial downloads and old metadata',
        () async {
      manager.setDefaultTTL(100);
      final nested = Directory(path.join(cacheDir.path, 'farm', 'videos'))
        ..createSync(recursive: true);
      final part = File(path.join(nested.path, 'abc.mp4.part'))
        ..writeAsStringSync('p')
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
      final legacy = File(path.join(nested.path, 'old.jpg'))
        ..writeAsStringSync('o');
      File(path.join(nested.path, 'old.jpg.metadata'))
          .writeAsStringSync('${_now() - 1000}');

      await manager.removeExpiredFiles();

      expect(part.existsSync(), isFalse);
      expect(legacy.existsSync(), isFalse);
    });
  });

  group('revalidation', () {
    test('keeps the file on 304 Not Modified and resets its age', () async {
      const url = 'https://cdn.test/x.jpg';
      var version = 'v1';
      useServer((request) async {
        if (request.headers['If-None-Match'] == '"$version"') {
          return http.Response('', 304, headers: {'etag': '"$version"'});
        }
        return http.Response('content-$version', 200,
            headers: {'etag': '"$version"'});
      });

      final first = await manager.getFile(url);
      final second = await manager.getFile(url, ttl: 0); // expired: revalidate
      expect(requests.last.headers['If-None-Match'], '"v1"');
      expect(second.path, first.path);
      expect(await second.readAsString(), 'content-v1');

      await manager.getFile(url, ttl: 100); // fresh again after the 304
      expect(requests, hasLength(2));

      version = 'v2'; // changed on the server
      final third = await manager.getFile(url, ttl: 0);
      expect(await third.readAsString(), 'content-v2');
    });
  });

  group('cacheKey', () {
    test('different URLs with one cacheKey share a file', () async {
      final a = await manager.getFile('https://cdn.test/x.jpg?sig=1',
          cacheKey: 'media-1');
      final b = await manager.getFile('https://cdn.test/x.jpg?sig=2',
          cacheKey: 'media-1');
      expect(requests, hasLength(1));
      expect(b.path, a.path);
    });
  });

  group('tags and pinning', () {
    test('tags accumulate, size by tag, clear by tag', () async {
      await manager.getFile('https://cdn.test/a.jpg', tags: {'farm:1'});
      await manager.getFile('https://cdn.test/a.jpg', tags: {'video'});
      await manager.getFile('https://cdn.test/b.jpg', tags: {'farm:2'});

      expect(await manager.getTagSize('farm:1'), 'body:/a.jpg'.length);
      expect(await manager.getTagSize('video'), 'body:/a.jpg'.length);

      await manager.clearTag('farm:1');

      expect(await manager.getTagSize('farm:1'), 0);
      expect(isCached('default', 'https://cdn.test/a.jpg'), isFalse);
      expect(isCached('default', 'https://cdn.test/b.jpg'), isTrue);
    });

    test('setPinned reports whether the file is cached', () async {
      const url = 'https://cdn.test/a.jpg';
      expect(await manager.setPinned(url, pinned: true), isFalse);
      await manager.getFile(url);
      expect(await manager.setPinned(url, pinned: true), isTrue);
      expect(await manager.getPinnedSize(), 'body:/a.jpg'.length);

      await manager.unpinAll();
      expect(await manager.getPinnedSize(), 0);
    });

    test('setTagPinned pins and unpins every file with the tag', () async {
      await manager.getFile('https://cdn.test/a.jpg', tags: {'farm:1'});
      await manager.getFile('https://cdn.test/b.jpg', tags: {'farm:2'});

      await manager.setTagPinned('farm:1', pinned: true);
      expect(await manager.getPinnedSize(), 'body:/a.jpg'.length);

      await manager.setTagPinned('farm:1', pinned: false);
      expect(await manager.getPinnedSize(), 0);
    });

    test('pinned files survive cleanup', () async {
      manager.setDefaultTTL(100);
      const url = 'https://cdn.test/pinned.jpg';
      writeEntry('default', url, 'p',
          fetchedAt: _now() - 10000,
          lastAccessedAt: _now() - 10000,
          pinned: true);

      await manager.removeExpiredFiles();

      expect(isCached('default', url), isTrue);
    });
  });

  group('size limit', () {
    test('evicts least recently used unpinned files first', () async {
      final old = _now() - 10000;
      writeEntry('f', 'https://cdn.test/1.jpg', '1' * 400,
          fetchedAt: old, lastAccessedAt: old + 1);
      writeEntry('f', 'https://cdn.test/2.jpg', '2' * 400,
          fetchedAt: old, lastAccessedAt: old, pinned: true);
      writeEntry('f', 'https://cdn.test/3.jpg', '3' * 400,
          fetchedAt: old, lastAccessedAt: old + 2);
      writeEntry('f', 'https://cdn.test/4.jpg', '4' * 400,
          fetchedAt: old, lastAccessedAt: old + 3);

      manager.setMaxCacheSize(1000); // 1600 bytes cached: trim to <= 900
      await manager.trimToMaxSize();

      expect(isCached('f', 'https://cdn.test/1.jpg'), isFalse); // oldest
      expect(isCached('f', 'https://cdn.test/2.jpg'), isTrue); // pinned
      expect(isCached('f', 'https://cdn.test/3.jpg'), isFalse);
      expect(isCached('f', 'https://cdn.test/4.jpg'), isTrue); // most recent
    });

    test('pinned files are evicted last when the limit overrides pins',
        () async {
      final old = _now() - 10000;
      writeEntry('f', 'https://cdn.test/p1.jpg', '1' * 400,
          fetchedAt: old, lastAccessedAt: old, pinned: true);
      writeEntry('f', 'https://cdn.test/p2.jpg', '2' * 400,
          fetchedAt: old, lastAccessedAt: old + 5, pinned: true);
      writeEntry('f', 'https://cdn.test/u.jpg', '3' * 400,
          fetchedAt: old, lastAccessedAt: old + 10);

      // 1200 bytes, limit 600: target 540. Without the override only the
      // unpinned file could go.
      manager.setMaxCacheSize(600);
      await manager.trimToMaxSize();
      expect(isCached('f', 'https://cdn.test/u.jpg'), isFalse);
      expect(isCached('f', 'https://cdn.test/p1.jpg'), isTrue);

      manager.setMaxCacheSize(600, overridePins: true);
      await manager.trimToMaxSize();
      expect(isCached('f', 'https://cdn.test/p1.jpg'), isFalse); // oldest pin
      expect(isCached('f', 'https://cdn.test/p2.jpg'), isTrue);
    });

    test('a file being used is not evicted', () async {
      final old = _now() - 10000;
      writeEntry('f', 'https://cdn.test/1.jpg', '1' * 400,
          fetchedAt: old, lastAccessedAt: old);
      manager.setMaxCacheSize(500);

      // Downloaded now, so in its grace period; the old file goes instead.
      await manager.getFile('https://cdn.test/new.jpg',
          folderName: 'f'); // 'body:/new.jpg'
      writeEntry('f', 'https://cdn.test/2.jpg', '2' * 400,
          fetchedAt: _now(), lastAccessedAt: _now());
      await manager.removeExpiredFiles(); // rebuilds nothing; trims

      expect(isCached('f', 'https://cdn.test/1.jpg'), isFalse);
      expect(isCached('f', 'https://cdn.test/2.jpg'), isTrue);
    });
  });

  group('moveCacheDirectory', () {
    test('renames the old directory when the new one does not exist',
        () async {
      final from = Directory(path.join(tempDir.path, 'docs', 'cache'))
        ..createSync(recursive: true);
      File(path.join(from.path, 'farm', 'a.jpg'))
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      final to = Directory(path.join(tempDir.path, 'support', 'cache'));

      final result = await CacheManager.moveCacheDirectory(from, to);

      expect(result.path, to.path);
      expect(File(path.join(to.path, 'farm', 'a.jpg')).readAsStringSync(),
          'a');
      expect(from.existsSync(), isFalse);
    });

    test('merges folders the new directory lacks', () async {
      final from = Directory(path.join(tempDir.path, 'docs', 'cache'));
      File(path.join(from.path, 'farmA', 'a.jpg'))
        ..createSync(recursive: true)
        ..writeAsStringSync('old-a');
      File(path.join(from.path, 'farmB', 'b.jpg'))
        ..createSync(recursive: true)
        ..writeAsStringSync('b');
      final to = Directory(path.join(tempDir.path, 'support', 'cache'));
      File(path.join(to.path, 'farmA', 'a.jpg'))
        ..createSync(recursive: true)
        ..writeAsStringSync('new-a');

      await CacheManager.moveCacheDirectory(from, to);

      expect(File(path.join(to.path, 'farmA', 'a.jpg')).readAsStringSync(),
          'new-a');
      expect(File(path.join(to.path, 'farmB', 'b.jpg')).readAsStringSync(),
          'b');
      expect(from.existsSync(), isFalse);
    });
  });

  group('folders', () {
    test('size of a missing folder is 0 and does not create it', () async {
      expect(await manager.getFolderSize('nothing'), 0);
      expect(Directory(path.join(cacheDir.path, 'nothing')).existsSync(),
          isFalse);
    });

    test('clearFolder removes files and bumps the generation', () async {
      await manager.getFile('https://cdn.test/x.jpg', folderName: 'images');
      final generation = manager.cacheGeneration;

      await manager.clearFolder('images');

      expect(await manager.getFolderSize('images'), 0);
      expect(manager.cacheGeneration, greaterThan(generation));
    });
  });

  group('CachedMediaWidget', () {
    Widget host(String url) => MaterialApp(
          home: CachedMediaWidget(
            url: url,
            placeholder: const Text('loading'),
            errorWidget: const Text('error'),
            builder: (context, file) => Text(file.readAsStringSync()),
          ),
        );

    // File I/O only completes outside the fake-async zone.
    Future<void> show(WidgetTester tester, Widget widget) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(widget);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    }

    testWidgets('shows the new file when the URL changes', (tester) async {
      await show(tester, host('https://cdn.test/one.jpg'));
      expect(find.text('body:/one.jpg'), findsOneWidget);

      await show(tester, host('https://cdn.test/two.jpg'));
      expect(find.text('body:/two.jpg'), findsOneWidget);
    });

    testWidgets('retries after a failure instead of remembering it',
        (tester) async {
      const url = 'https://cdn.test/retry.jpg';
      useOffline();
      await show(tester, host(url));
      expect(find.text('error'), findsOneWidget);

      useServer();
      await tester.pumpWidget(const SizedBox());
      await show(tester, host(url));
      expect(find.text('body:/retry.jpg'), findsOneWidget);
    });
  });

  group('formatBytes', () {
    test('formats sizes', () {
      expect(CacheManagerStats.formatBytesStatic(0), equals('0 B'));
      expect(CacheManagerStats.formatBytesStatic(1023), equals('1023.00 B'));
      expect(CacheManagerStats.formatBytesStatic(1024), equals('1.00 KB'));
      expect(CacheManagerStats.formatBytes(1048576), equals('1.00 MB'));
      expect(CacheManagerStats.formatBytes(1073741824), equals('1.00 GB'));
    });

    test('respects decimals and does not overflow past TB', () {
      expect(CacheManagerStats.formatBytes(1500, decimals: 0), equals('1 KB'));
      expect(CacheManagerStats.formatBytes(1500, decimals: 1), equals('1.5 KB'));
      expect(FileUtils.formatBytes(1024 * 1024 * 1024 * 1024 * 2048),
          equals('2048.00 TB'));
    });
  });
}
