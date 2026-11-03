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
      {required int fetchedAt, required int lastAccessedAt, int? ttl}) {
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
    }));
  }

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
