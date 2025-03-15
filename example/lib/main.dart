import 'package:flutter/material.dart';
import 'package:flutter_cache_maestro/flutter_cache_maestro.dart';
import 'dart:io';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize cache maestro with custom settings
  await CacheManager().init(
    defaultTTL: 7 * 86400, // 7 days in seconds
    redownloadEnabled: false, // Use cached files when available
  );
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Cache Manager Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  CacheStats? _cacheStats;
  final List<String> _imageUrls = [
    'https://picsum.photos/400/300',
    'https://picsum.photos/400/301',
    'https://picsum.photos/400/302',
  ];
  final List<String> _pdfUrls = [
    'https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf',
  ];

  @override
  void initState() {
    super.initState();
    _loadCacheStats();
  }

  Future<void> _loadCacheStats() async {
    final stats = await CacheManager().getCacheStats();
    setState(() {
      _cacheStats = stats;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cache Manager Demo'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cache Stats Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Cache Statistics',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_cacheStats != null) ...[
                      Text('Total Folders: ${_cacheStats!.folderCount}'),
                      Text(
                        'Total Size: ${CacheManagerStats.formatBytes(_cacheStats!.totalSize)}',
                      ),
                      const SizedBox(height: 8),
                      const Text('Folder Sizes:'),
                      ...(_cacheStats!.folderSizes.entries.map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(left: 16.0),
                          child: Text(
                            '${entry.key}: ${CacheManagerStats.formatBytes(entry.value)}',
                          ),
                        ),
                      )),
                    ] else ...[
                      const Text('Loading cache statistics...'),
                    ],
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Cached Images Section
            const Text(
              'Cached Images',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _imageUrls.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: CachedImage(
                      url: _imageUrls[index],
                      folderName: 'images',
                      fit: BoxFit.cover,
                      width: 150,
                      height: 200,
                      placeholder: const Center(
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  );
                },
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Cached PDF Section
            const Text(
              'Cached PDFs',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _pdfUrls.length,
              itemBuilder: (context, index) {
                return Card(
                  child: ListTile(
                    title: Text('PDF ${index + 1}'),
                    subtitle: Text(_pdfUrls[index]),
                    trailing: FutureBuilder<File>(
                      future: CacheManager().getFile(
                        _pdfUrls[index],
                        folderName: 'pdfs',
                      ),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const CircularProgressIndicator();
                        } else if (snapshot.hasData) {
                          return const Icon(Icons.file_present, color: Colors.green);
                        } else {
                          return const Icon(Icons.error, color: Colors.red);
                        }
                      },
                    ),
                    onTap: () async {
                      // Store context in local variable to safely use after async gap
                      final currentContext = context;
                      try {
                        final file = await CacheManager().getFile(
                          _pdfUrls[index],
                          folderName: 'pdfs',
                        );
                        // Here you would open the PDF file using a PDF viewer plugin
                        if (!mounted) return;
                        ScaffoldMessenger.of(currentContext).showSnackBar(
                          SnackBar(content: Text('PDF saved at: ${file.path}')),
                        );
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(currentContext).showSnackBar(
                          SnackBar(content: Text('Error: $e')),
                        );
                      }
                    },
                  ),
                );
              },
            ),
            
            const SizedBox(height: 16),
            
            // Cache Management Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: () async {
                    await CacheManager().clearFolder('images');
                    await _loadCacheStats();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Images cache cleared')),
                    );
                  },
                  child: const Text('Clear Images'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await CacheManager().clearFolder('pdfs');
                    await _loadCacheStats();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('PDFs cache cleared')),
                    );
                  },
                  child: const Text('Clear PDFs'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await CacheManager().clearAllCache();
                    await _loadCacheStats();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('All cache cleared')),
                    );
                  },
                  child: const Text('Clear All'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: () {
                    CacheManager().setDefaultTTL(24 * 60 * 60); // 1 day
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('TTL set to 1 day')),
                    );
                  },
                  child: const Text('TTL: 1 Day'),
                ),
                ElevatedButton(
                  onPressed: () {
                    CacheManager().setDefaultTTL(7 * 24 * 60 * 60); // 7 days
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('TTL set to 7 days')),
                    );
                  },
                  child: const Text('TTL: 7 Days'),
                ),
                ElevatedButton(
                  onPressed: () {
                    // Toggle redownload setting
                    bool newValue = true; // Default to enabling
                    CacheManager().setRedownloadEnabled(newValue);
                    
                    // Show the current state
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Redownload enabled'),
                      ),
                    );
                  },
                  child: const Text('Toggle Redownload'),
                ),
              ],
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loadCacheStats,
        tooltip: 'Reload Stats',
        child: const Icon(Icons.refresh),
      ),
    );
  }
}