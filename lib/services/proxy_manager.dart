// ECH 代理管理：加载 native 库、初始化、获取资源并缓存
// ⚠️ 此文件实现核心 ECH 代理功能，是 app 联网的基础，不可删除。
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();

typedef _EchStrNative = Void Function(Pointer<Utf8>);
typedef _EchStrDart = void Function(Pointer<Utf8>);

typedef _EchInitWithBootstrapNative = Void Function(
    Pointer<Utf8>, Pointer<Utf8>);
typedef _EchInitWithBootstrapDart = void Function(
    Pointer<Utf8>, Pointer<Utf8>);

typedef _EchInitReadyNative = Int32 Function();
typedef _EchInitReadyDart = int Function();

typedef _EchLastErrorNative = Pointer<Utf8> Function();
typedef _EchLastErrorDart = Pointer<Utf8> Function();

typedef _EchFetchNative = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _EchFetchDart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _EchLogCountNative = Int32 Function();
typedef _EchLogCountDart = int Function();

typedef _EchGetLogNative = Pointer<Utf8> Function(Int32);
typedef _EchGetLogDart = Pointer<Utf8> Function(int);

typedef _FreeCStringNative = Void Function(Pointer<Utf8>);
typedef _FreeCStringDart = void Function(Pointer<Utf8>);

class ProxyManager {
  // Native library handling (platform‑specific) and lazy download on first use
  DynamicLibrary? _lib;
  _EchStrDart? _setDohURL;
  _VoidDart? _initFfi;
  _EchInitWithBootstrapDart? _initWithBootstrap;
  _EchInitReadyDart? _ready;
  _EchLastErrorDart? _lastError;
  _EchFetchDart? _fetchFfi;
  _EchLogCountDart? _logCount;
  _EchGetLogDart? _getLog;
  _FreeCStringDart? _free;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  Future<void> load() async {
    // Determine platform‑specific library name
    String libName;
    String downloadUrl;
    if (Platform.isWindows) {
      libName = 'echproxy.dll';
      // TODO: replace with actual URL for Windows build
      downloadUrl = 'https://ghproxy.com/https://github.com/Hana-ame/twitter-pic-flutter/releases/download/v0.2.0/echproxy.dll';
    } else if (Platform.isLinux) {
      libName = 'libechproxy.so';
      downloadUrl = 'https://ghproxy.com/https://github.com/Hana-ame/twitter-pic-flutter/releases/download/v0.2.0/libechproxy.so';
    } else if (Platform.isMacOS) {
      libName = 'libechproxy.dylib';
      downloadUrl = 'https://ghproxy.com/https://github.com/Hana-ame/twitter-pic-flutter/releases/download/v0.2.0/libechproxy.dylib';
    } else {
      libName = 'libechproxy.so';
      downloadUrl = 'https://example.com/echproxy/default/libechproxy.so';
    }

    // Try to load from bundled assets (relative to executable)
    try {
      _lib = DynamicLibrary.open(libName);
    } catch (_) {
      // If not present, download to app support directory and load from there
      final dir = await getApplicationSupportDirectory();
      final libPath = '${dir.path}/$libName';
      final libFile = File(libPath);
      if (!await libFile.exists()) {
        // download native library
        final client = HttpClient();
        final request = await client.getUrl(Uri.parse(downloadUrl));
        final response = await request.close();
        if (response.statusCode != 200) {
          throw Exception('Failed to download native lib: HTTP ${response.statusCode}');
        }
        final bytes = await response.fold<Uint8List>(Uint8List(0), (previous, element) => Uint8List.fromList(previous + element));
        await libFile.writeAsBytes(bytes);
      }
      _lib = DynamicLibrary.open(libPath);
    }
    _setDohURL =
        _lib!.lookupFunction<_EchStrNative, _EchStrDart>('ECHSetDohURL');
    _initFfi = _lib!.lookupFunction<_VoidNative, _VoidDart>('ECHInit');
    _initWithBootstrap =
        _lib!.lookupFunction<_EchInitWithBootstrapNative,
            _EchInitWithBootstrapDart>('ECHInitWithBootstrap');
    _ready = _lib!.lookupFunction<_EchInitReadyNative, _EchInitReadyDart>(
        'ECHInitReady');
    _lastError =
        _lib!.lookupFunction<_EchLastErrorNative, _EchLastErrorDart>(
            'ECHInitLastError');
    _fetchFfi =
        _lib!.lookupFunction<_EchFetchNative, _EchFetchDart>('ECHFetch');
    _logCount =
        _lib!.lookupFunction<_EchLogCountNative, _EchLogCountDart>(
            'ECHGetLogCount');
    _getLog = _lib!.lookupFunction<_EchGetLogNative, _EchGetLogDart>(
        'ECHGetLog');
    _free =
        _lib!.lookupFunction<_FreeCStringNative, _FreeCStringDart>(
            'FreeCString');
  }

  // 初始化 ECH 代理，支持自定义 DoH 配置
  Future<void> init({String? dohUrl, String? dohHost, String? dohBootstrapIP}) async {
    await load();
    if (dohUrl != null) {
      using((Arena arena) {
        _setDohURL!(dohUrl.toNativeUtf8(allocator: arena));
      });
    }
    if (dohHost != null) {
      using((Arena arena) {
        _initWithBootstrap!(
          dohHost.toNativeUtf8(allocator: arena),
          (dohBootstrapIP ?? '').toNativeUtf8(allocator: arena),
        );
      });
    } else {
      _initFfi!();
    }
  }

  // 等待 ECH 初始化完成，超时或错误则抛异常
  Future<void> waitForInit() async {
    for (var i = 0; i < 150; i++) {
      final status = _ready!();
      if (status == 1) {
        _initialized = true;
        return;
      }
      if (status == -1) {
        final errPtr = _lastError!();
        final msg = errPtr != nullptr ? errPtr.toDartString() : 'unknown error';
        if (errPtr != nullptr) _free!(errPtr);
        throw Exception('ECH init error: $msg');
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    throw Exception('ECH init timeout after 30s');
  }

  List<String> getLogs() {
    final n = _logCount!();
    final list = <String>[];
    for (var i = 0; i < n; i++) {
      final ptr = _getLog!(i);
      if (ptr != nullptr) {
        list.add(ptr.toDartString());
        _free!(ptr);
      }
    }
    return list;
  }

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

  Uint8List? fetch(String url) {
    final cached = _imageCache[url];
    if (cached != null) return cached;
    final bytes = using((Arena arena) {
      final uri = Uri.parse(url).replace(
        scheme: 'https',
        host: 'video-cf.twimg.com',
      );
      final urlPtr = uri.toString().toNativeUtf8(allocator: arena);
      final hostPtr = 'video-cf.twimg.com'.toNativeUtf8(allocator: arena);
      final refererPtr = 'https://x.com'.toNativeUtf8(allocator: arena);

      final result = _fetchFfi!(urlPtr, hostPtr, refererPtr);
      if (result == nullptr) return null;

      final str = result.toDartString();
      _free!(result);
      if (str.startsWith('ERR: ')) throw Exception(str.substring(5));
      return base64Decode(str);
    });
    if (bytes != null) _imageCache[url] = bytes;
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
          await proxy.load();
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
    _initialized = false;
  }
}
