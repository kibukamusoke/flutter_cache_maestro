// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing


import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_cache_maestro/flutter_cache_maestro.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CacheManager initialization test', (WidgetTester tester) async {
    final cacheManager = CacheManager();
    await cacheManager.init();
    
    // Verify that CacheManager can be initialized without errors
    expect(cacheManager, isA<CacheManager>());
    
    // Test cache statistics
    final stats = await cacheManager.getCacheStats();
    expect(stats, isA<CacheStats>());
    expect(stats.folderCount, isNotNull);
  });
}
