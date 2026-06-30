import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

class ProxyManager {
  bool _initialized = false;
  late HttpClient _client;

  bool get isInitialized => _initialized;

  Future<void> init({String? dohUrl, String? dohHost, String? dohBootstrapIP}) async {
    _client = HttpClient();
    _client.userAgent = 'TwitterPic/1.0';
    _client.connectionTimeout = const Duration(seconds: 15);
    _initialized = true;
  }

  Future<void> waitForInit() async {
    // No native init needed, just mark ready
    _initialized = true;
  }

  List<String> getLogs() => [];

  static final Map<String, Uint8List> _imageCache = {};
  static final Map<String, ui.Size> sizeCache = {};

  static Future<ui.Size?> decodeImageSize(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return ui.Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> fetch(String url) async {
    final cached = _imageCache[url];
    if (cached != null) return cached;

    final parsed = Uri.parse(url);
    final request = await _client.getUrl(parsed);
    request.headers.set('Referer', 'https://x.com');
    final response = await request.close();
    if (response.statusCode != 200) {
      return null;
    }
    final bytes = await response.fold<Uint8List>(
      Uint8List(0),
      (prev, chunk) => Uint8List.fromList([...prev, ...chunk]),
    );
    _imageCache[url] = bytes;
    return bytes;
  }

  Future<Uint8List?> fetchAsync(String url) async {
    final cached = _imageCache[url];
    if (cached != null) return cached;

    const maxRetries = 3;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final bytes = await Isolate.run(() async {
          final proxy = ProxyManager();
          await proxy.init();
          return proxy.fetch(url);
        });
        if (bytes != null) _imageCache[url] = bytes;
        return bytes;
      } catch (e) {
        if (attempt == maxRetries - 1) rethrow;
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    return null;
  }

  void dispose() {
    _client.close(force: true);
  }
}
