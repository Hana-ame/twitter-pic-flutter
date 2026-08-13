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

// Top‑level function for Isolate.run — no this capture, fully sendable.
// Opens the native library by SONAME inside the isolate (same approach as v0.2.4).
Uint8List? _isolateFetchSingle(List<String> args) {
  final url = args[0];
  final proxy = ProxyManager();
  _openBundled(proxy);
  return proxy.fetch(url);
}

// Top‑level function for Isolate.run — streaming download to a local file.
// 返回字节数；异常会通过 isolate 传递到调用方。文件是分块写入的，
// 不会把整个视频读进内存。
int _isolateDownloadToFile(List<String> args) {
  final url = args[0];
  final path = args[1];
  final proxy = ProxyManager();
  _openBundled(proxy);
  return proxy.fetchToFile(url, path);
}

void _openBundled(ProxyManager proxy) {
  String libName;
  if (Platform.isWindows) {
    libName = 'echproxy.dll';
  } else if (Platform.isLinux) {
    libName = 'libechproxy.so';
  } else if (Platform.isMacOS) {
    libName = 'libechproxy.dylib';
  } else {
    libName = 'libechproxy.so';
  }
  proxy.openLibWithPath(libName);
}

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

// 流式下载接口（Go 侧 ech-shared v2）：
// ECHFetchBegin 返回 uintptr 句柄（0 表示失败），ECHRead 分块读取
// （>0 字节数 / 0=EOF / -1=读取错误 / -2=无效句柄），ECHClose 释放。
// 句柄跨 FFI 用整数传递（runtime/cgo.Handle），不经过 unsafe.Pointer。
typedef _EchFetchBeginNative = UintPtr Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _EchFetchBeginDart = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _EchReadNative = Int32 Function(UintPtr, Pointer<Uint8>, Int32);
typedef _EchReadDart = int Function(int, Pointer<Uint8>, int);

typedef _EchCloseNative = Void Function(UintPtr);
typedef _EchCloseDart = void Function(int);

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
  _EchFetchBeginDart? _fetchBegin;
  _EchReadDart? _readChunk;
  _EchCloseDart? _closeHandle;
  _EchLogCountDart? _logCount;
  _EchGetLogDart? _getLog;
  _FreeCStringDart? _free;
  bool _initialized = false;

  // Absolute path of the DLL successfully loaded on the main isolate.
  static String? resolvedLibPath;

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
      resolvedLibPath = libName;
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
      resolvedLibPath = libPath;
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
    _fetchBegin =
        _lib!.lookupFunction<_EchFetchBeginNative, _EchFetchBeginDart>(
            'ECHFetchBegin');
    _readChunk =
        _lib!.lookupFunction<_EchReadNative, _EchReadDart>('ECHRead');
    _closeHandle =
        _lib!.lookupFunction<_EchCloseNative, _EchCloseDart>('ECHClose');
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
  Future<void> waitForInit({int timeoutSecs = 900}) async {
    for (var i = 0; i < timeoutSecs * 5; i++) {
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
    throw Exception('ECH init timeout after ${timeoutSecs}s');
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

  Future<Uint8List?> fetchAsync(String url, {int timeoutSecs = 1800}) async {
    final cached = _imageCache[url];
    if (cached != null) return cached;
    const maxRetries = 3;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final bytes = await Isolate.run(() => _isolateFetchSingle([url]))
            .timeout(Duration(seconds: timeoutSecs));
        if (bytes != null) _imageCache[url] = bytes;
        return bytes;
      } catch (e) {
        if (attempt == maxRetries - 1) rethrow;
        await Future.delayed(Duration(seconds: 5 * (attempt + 1)));
      }
    }
    return null;
  }

  // 流式下载到文件：分块读取（ECHFetchBegin/ECHRead），边下边写盘，
  // 全程内存占用恒定（64KB buffer），大视频不再爆内存。
  // 必须只在工作 isolate 中调用（阻塞式 FFI 读取），返回下载字节数。
  int fetchToFile(String url, String path) {
    final uri = Uri.parse(url).replace(
      scheme: 'https',
      host: 'video-cf.twimg.com',
    );
    final handle = using((Arena arena) {
      final urlPtr = uri.toString().toNativeUtf8(allocator: arena);
      final hostPtr = 'video-cf.twimg.com'.toNativeUtf8(allocator: arena);
      final refererPtr = 'https://x.com'.toNativeUtf8(allocator: arena);
      return _fetchBegin!(urlPtr, hostPtr, refererPtr);
    });
    if (handle == 0) throw Exception('ECHFetchBegin failed (see Go logs)');
    try {
      final raf = File(path).openSync(mode: FileMode.write);
      try {
        final buf = calloc<Uint8>(_kStreamBufSize);
        try {
          var total = 0;
          while (true) {
            final n = _readChunk!(handle, buf, _kStreamBufSize);
            if (n == 0) break; // EOF
            if (n < 0) throw Exception('ECHRead error: $n');
            raf.writeFromSync(buf.asTypedList(n));
            total += n;
          }
          return total;
        } finally {
          calloc.free(buf);
        }
      } finally {
        raf.closeSync();
      }
    } finally {
      _closeHandle!(handle);
    }
  }

  static const int _kStreamBufSize = 64 * 1024;

  // 带超时与重试的流式下载入口（主 isolate 安全）。
  Future<int> fetchToFileAsync(String url, String path,
      {int timeoutSecs = 1800}) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await Isolate.run(() => _isolateDownloadToFile([url, path]))
            .timeout(Duration(seconds: timeoutSecs));
      } catch (e) {
        if (attempt == 2) rethrow;
        await Future.delayed(Duration(seconds: 5 * (attempt + 1)));
      }
    }
    throw Exception('unreachable');
  }

  // Open native library by absolute path. Pure sync — safe in worker isolates.
  // Caller must ensure the DLL is already loaded in the process (ref‑counted).
  void openLibWithPath(String path) {
    if (_lib != null) return;
    _lib = DynamicLibrary.open(path);
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
    _fetchBegin =
        _lib!.lookupFunction<_EchFetchBeginNative, _EchFetchBeginDart>(
            'ECHFetchBegin');
    _readChunk =
        _lib!.lookupFunction<_EchReadNative, _EchReadDart>('ECHRead');
    _closeHandle =
        _lib!.lookupFunction<_EchCloseNative, _EchCloseDart>('ECHClose');
    _logCount =
        _lib!.lookupFunction<_EchLogCountNative, _EchLogCountDart>(
            'ECHGetLogCount');
    _getLog = _lib!.lookupFunction<_EchGetLogNative, _EchGetLogDart>(
        'ECHGetLog');
    _free =
        _lib!.lookupFunction<_FreeCStringNative, _FreeCStringDart>(
            'FreeCString');
  }

  void dispose() {
    _initialized = false;
  }
}
