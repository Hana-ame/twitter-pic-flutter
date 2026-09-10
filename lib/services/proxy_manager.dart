// proxy_manager.dart
// ECH 代理生命周期管理：启动 / 停止 / 获取端口。
//
// 相比旧版（v0.2.8），删除了所有 per-request FFI 调用：
//   - fetchAsync / fetch / fetchToFile / fetchToFileAsync  → 删除
//   - _isolateFetchSingle / _isolateDownloadToFile         → 删除
//   - lru_image_cache 大部分逻辑                            → 删除（交给框架缓存）
//   - sizeCache / decodeImageSize                           → 删除（交给 ImageProvider）
//
// 只保留：
//   - openLib / openLibWithPath（加载 .so/.dll）
//   - init（FFI 初始化）
//   - waitForInit（等 ECH 就绪）
//   - start（启动代理，返回端口）
//   - stop（停止代理）
//   - restart（重启代理）
//   - getLogs（调试日志）

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../api/twitter_api.dart';

// ─── FFI typedef（必须在顶层定义，不能在 class 内部）──────────────────────

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

typedef _EchLogCountNative = Int32 Function();
typedef _EchLogCountDart = int Function();

typedef _EchGetLogNative = Pointer<Utf8> Function(Int32);
typedef _EchGetLogDart = Pointer<Utf8> Function(int);

typedef _FreeCStringNative = Void Function(Pointer<Utf8>);
typedef _FreeCStringDart = void Function(Pointer<Utf8>);

typedef _StartProxyNative = Uint16 Function(Pointer<Utf8>);
typedef _StartProxyDart = int Function(Pointer<Utf8>);

typedef _StopProxyNative = Void Function();
typedef _StopProxyDart = void Function();

class ProxyManager {
  // ─── Native 库句柄 ───────────────────────────────────────────────────────
  DynamicLibrary? _lib;
  bool _initialized = false;

  // ─── FFI 函数指针 ────────────────────────────────────────────────────────
  _EchInitWithBootstrapDart? _initWithBootstrap;
  _EchInitReadyDart? _ready;
  _EchLastErrorDart? _lastError;
  _EchStrDart? _setDohURL;
  _EchLogCountDart? _logCount;
  _EchGetLogDart? _getLog;
  _FreeCStringDart? _free;

  // 新增：代理启停
  _StartProxyDart? _startProxy;
  _StopProxyDart? _stopProxy;

  // ─── 状态 ────────────────────────────────────────────────────────────────
  int? _port;
  bool _startInFlight = false;
  // 端口变化通知：UI 侧（如 ProxyAvatar）据此重新尝试经代理加载。没有它，
  // 头像一旦降级到直连就再也不会回到 ECH 通道（IndexedStack 不重建父级，
  // didUpdateWidget 的 port 比对永不触发）。
  final ValueNotifier<int?> _portNotifier = ValueNotifier(null);

  // ─── 公共 API ────────────────────────────────────────────────────────────

  /// 启动 ECH 代理，返回监听端口。
  ///
  /// [bootstrapIp] DoH 服务器的 IP 地址（由 Dart 侧 DNS 解析得到）
  /// [dohUrl] DoH URL，默认 `https://moonchan.xyz/doh`
  /// [dohHost] DoH 域名，默认 `moonchan.xyz`
  ///
  /// 失败时抛出异常。
  Future<int> start({
    required String bootstrapIp,
    String dohUrl = 'https://moonchan.xyz/doh',
    String dohHost = 'moonchan.xyz',
  }) async {
    if (_startInFlight) {
      throw Exception('start() already in progress');
    }
    _startInFlight = true;
    try {
      await _loadLib();
      await _initEch(dohUrl: dohUrl, dohHost: dohHost, bootstrapIp: bootstrapIp);
      await _waitForInit();

      // 启动代理
      final port = _startProxyFfi(bootstrapIp);
      if (port == 0) {
        throw Exception('StartProxy failed (port=0, see Go logs)');
      }
      _port = port;
      _portNotifier.value = port;
      // 所有 API 请求统一走代理 endpoint。
      ApiEndpoint.useProxyEndpoint(port);
      return port;
    } finally {
      _startInFlight = false;
    }
  }

  /// 停止代理。幂等：未启动时调用无副作用。
  void stop() {
    _stopProxyFfi();
    _port = null;
    _portNotifier.value = null;
    ApiEndpoint.useProxyEndpoint(null);
  }

  /// 重启代理：停止 → 重新启动。
  /// 端口可能变化（系统随机分配），调用方需更新 EchUrl 中的端口。
  Future<int> restart({
    required String bootstrapIp,
    String dohUrl = 'https://moonchan.xyz/doh',
    String dohHost = 'moonchan.xyz',
  }) async {
    stop();
    return start(
      bootstrapIp: bootstrapIp,
      dohUrl: dohUrl,
      dohHost: dohHost,
    );
  }

  /// 代理监听端口。未启动时为 null。
  int? get port => _port;

  /// 端口变化监听（start/stop/restart 后通知）。UI 侧订阅它可以在代理
  /// 重启后重新尝试经代理加载资源。
  ValueListenable<int?> get portNotifier => _portNotifier;

  /// 代理是否正在运行。
  bool get isRunning => _port != null;

  /// 初始化是否完成。
  bool get isInitialized => _initialized;

  /// 是否正在启动中。
  bool get isStarting => _startInFlight;

  /// 获取 Go 侧日志（调试用）。
  List<String> getLogs() {
    // native 库未加载（_loadLib 失败）时返回空列表：直接解引用 _logCount!
    // 会抛 "Null check operator used on a null value"，把真实的
    // "Native library not found" 错误掩盖掉。
    if (_logCount == null || _getLog == null || _free == null) return const [];
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

  /// 释放资源。App 退出时调用。
  void dispose() {
    stop();
    _initialized = false;
    _portNotifier.dispose();
  }

  // ─── 内部实现 ────────────────────────────────────────────────────────────

  Future<void> _loadLib() async {
    if (_lib != null) return; // 已加载

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

    // 优先从 assets 加载（CI 打包后）
    try {
      _lib = DynamicLibrary.open(libName);
    } catch (_) {
      // 回退：从应用支持目录加载（下载或内置）
      final dir = await getApplicationSupportDirectory();
      final libPath = '${dir.path}/$libName';
      final libFile = File(libPath);
      if (!await libFile.exists()) {
        throw Exception(
            'Native library not found: $libName\n'
            'Place it in assets or app support directory.');
      }
      _lib = DynamicLibrary.open(libPath);
    }

    // 加载所有 FFI 函数指针
    _initWithBootstrap = _lib!.lookupFunction<
        _EchInitWithBootstrapNative, _EchInitWithBootstrapDart>(
        'ECHInitWithBootstrap');
    _ready = _lib!.lookupFunction<_EchInitReadyNative, _EchInitReadyDart>(
        'ECHInitReady');
    _lastError = _lib!.lookupFunction<_EchLastErrorNative, _EchLastErrorDart>(
        'ECHInitLastError');
    _setDohURL =
        _lib!.lookupFunction<_EchStrNative, _EchStrDart>('ECHSetDohURL');
    _logCount =
        _lib!.lookupFunction<_EchLogCountNative, _EchLogCountDart>(
            'ECHGetLogCount');
    _getLog = _lib!.lookupFunction<_EchGetLogNative, _EchGetLogDart>(
        'ECHGetLog');
    _free =
        _lib!.lookupFunction<_FreeCStringNative, _FreeCStringDart>(
            'FreeCString');

    // 新增：代理接口（如果库版本太旧可能没有这些符号，做 graceful fallback）
    try {
      _startProxy = _lib!.lookupFunction<_StartProxyNative, _StartProxyDart>(
          'StartProxy');
    } catch (_) {
      _startProxy = null; // 旧版库无此符号
    }
    try {
      _stopProxy = _lib!.lookupFunction<_StopProxyNative, _StopProxyDart>(
          'StopProxy');
    } catch (_) {
      _stopProxy = null;
    }
  }

  Future<void> _initEch({
    required String dohUrl,
    required String dohHost,
    required String bootstrapIp,
  }) async {
    await _loadLib();

    using((Arena arena) {
      final urlPtr = dohUrl.toNativeUtf8(allocator: arena);
      _setDohURL!(urlPtr);

      final hostPtr = dohHost.toNativeUtf8(allocator: arena);
      final ipPtr = bootstrapIp.toNativeUtf8(allocator: arena);
      _initWithBootstrap!(hostPtr, ipPtr);
    });
  }

  Future<void> _waitForInit({int timeoutSecs = 900}) async {
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

  int _startProxyFfi(String bootstrapIp) {
    if (_startProxy == null) {
      throw Exception(
          'StartProxy not available in this library version. '
          'Please update libechproxy.so to v2+ with proxy support.');
    }
    return using((Arena arena) {
      final ipPtr = bootstrapIp.toNativeUtf8(allocator: arena);
      return _startProxy!(ipPtr);
    });
  }

  void _stopProxyFfi() {
    _stopProxy?.call();
  }
}

// ─── 辅助：获取应用支持目录 ──────────────────────────────────────────────────

Future<Directory> getApplicationSupportDirectory() async {
  // 使用 path_provider 包
  // 如果不想依赖 path_provider，可以用以下简化实现：
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        r'C:\Users';
    final dir = Directory('$localAppData\\TwitterPic');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  } else if (Platform.isLinux) {
    final xdgData = Platform.environment['XDG_DATA_HOME'] ??
        '${Platform.environment['HOME']}/.local/share';
    final dir = Directory('$xdgData/TwitterPic');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  } else {
    // Android: 使用 Flutter 的 path_provider
    throw UnsupportedError(
        'Use path_provider package for Android directory resolution');
  }
}
