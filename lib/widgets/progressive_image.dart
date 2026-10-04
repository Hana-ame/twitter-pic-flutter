// progressive_image.dart
// 边下边显的图片通道。
//
// 背景：Flutter 自带的 NetworkImage 会先把整个响应体读完（
// consolidateHttpClientResponseBytes）才交给解码器。于是一张 2MB 的图在墙内
// 经 ECH 代理慢慢下的时候，屏幕上是一大片空白——这正是"看不到 media"的观感
// 来源之一。这里改成：HTTP 流每收到一块就尝试解码当前已收到的字节，
// 解出什么就先画什么（JPEG/Skia 对不完整数据会做部分解码，未下载到的部分
// 是中性灰），后面的分块再把画面逐次刷新到更清晰。
//
// 解码是节流的：部分解码等于把当前缓冲整张重解一遍，必须限制频率（增量
// 太小、间隔太短都不解）。PNG 等不支持部分解码的格式会自动退化为
// "下完再显示"，只是没有中间帧，不会报错。
//
// ── 关于「滚出视口 / pop 页面就取消下载」：试过，做不了，原因记在这里 ──
//
// 直觉做法是监听 listener 数量，最后一个走了就中止 HTTP。但在 Flutter 里这是
// 空操作，原因在 image_cache.dart：`ImageCache.putIfAbsent` 对每一个它加载的
// completer 都会加**自己**的 ImageStreamListener（`_PendingImage`），并且只在
// 图片**完成**时才移除。所以下载期间 listener 计数永远不会掉到 0，
// `ImageStreamCompleter` 内部的 `_maybeDispose` 不触发，`onDisposed` 和
// `addOnLastListenerRemovedCallback` 都只能在下载结束之后才响。
//
// 真要取消就得从 `ProgressiveImage` 的 dispose 反推「还有几张卡片在用这个
// URL」，那要按 URL 维护引用计数 —— 而 `ProgressiveImageProvider` 按 URL
// `==` 共享、被 ImageCache 缓存，同一 URL 的多张卡片共用一个 completer，
// provider 自己无法知道「还剩几个使用者」。那属于另一量级的改动（要动 provider
// 的构造/缓存模型），收益（省几秒带宽）不抵风险（漏减一次计数就再也拉不回图）。
//
// 顺手记下两个坑，免得下次重踩：
//   * Flutter 3.44.3 的 `ImageStreamCompleter` **没有 `dispose()`**（它不是
//     ChangeNotifier），`@override void dispose()` 直接编译错
//     `undefined_super_member`；生命周期钩子是 `onDisposed()`（@protected，
//     必须调 super）。
//   * 一旦内部 `_disposed` 置位，`setImage` / `reportError` / `addListener`
//     全都会抛 `StateError('Stream has been disposed...')`，所以任何「已废弃」
//     标记都必须守住每一处框架调用，否则异步里抛 StateError 就成未处理异常。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/stable_hash.dart';

/// 部分解码节流器。
///
/// 三个条件同时满足才解码：
///   * 新增字节 >= [minDeltaBytes]（几十 KB 才值得重解一次）；
///   * 新增字节 >= 已解码量的 1/4（越往后越稀疏，接近几何级数）；
///   * 距上次解码 >= [minInterval]（快网络上别把 CPU 打满）。
class ProgressiveDecodeThrottle {
  ProgressiveDecodeThrottle({
    this.minDeltaBytes = 24 * 1024,
    this.minInterval = const Duration(milliseconds: 120),
  });

  final int minDeltaBytes;
  final Duration minInterval;

  int _lastBytes = 0;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool shouldDecode(int loadedBytes, DateTime now) {
    final delta = loadedBytes - _lastBytes;
    if (delta < minDeltaBytes) return false;
    if (delta < _lastBytes ~/ 4) return false;
    return now.difference(_lastAt) >= minInterval;
  }

  void mark(int loadedBytes, DateTime now) {
    _lastBytes = loadedBytes;
    _lastAt = now;
  }
}

/// 磁盘缓存：解码后的字节（不是解码后的位图）。
///
/// v0.6.1 新增。此前 [ProgressiveImageProvider] 只命中 Flutter 的 ImageCache
/// （**纯内存**），于是内存一挤（160MB 上限，列表滚两屏就满），再滚回来就得
/// **重新经 ECH 下一次原图**——墙内 7~11s起步，观感就是"白一下再出来"。
///
/// 存字节而不是位图的原因：位图解码一次几百毫秒、占几MB，写盘和读盘都很贵；
/// 而磁盘上放字节，读回来后走 `decode` 内存缓存命中，比重新下载快一个量级。
///
/// 键是 URL 的 stableHash —— 与 [ProgressiveImageProvider] 的相等性判据同源
/// （[ImageCache] 按 URL 判等，这里按 URL 的哈希分文件），所以内存缓存命中时
/// 磁盘缓存 key 也一致，两层对得上。
///
/// 未就绪（还没 [ensureInitialized]、或没有可写目录）时**静默降级为纯内存**：
/// 磁盘缓存只是加速，不是功能，绝不能因为它让图加载不出来。
class ProgressiveDiskCache {
  ProgressiveDiskCache._();

  /// 目录名（在应用支持目录下，与 PosterService 同级）。
  static const String dirName = 'image-cache';

  /// 磁盘缓存条目上限，按**累计写入顺序**淘汰（LRU）。
  ///
  /// 2 万条、平均 150KB ≈ 3GB，太大；10 万条平均 60KB（缩略图档位下更小）
  /// ≈ 1~2GB，对一个看图应用是可接受的量。缩略图档位进来后单条更小，
  /// 实际占用远低于这个上界。
  static const int maxEntries = 10000;

  /// 单条上限：超过这个大小直接不缓存。
  ///
  /// 原图动辄 2MB，但**原图只在详情页/全屏预览用**，那张图本来就不该被反复
  /// 下（看过一次就够了）。真正需要反复出现的是列表缩略图（几十 KB）。
  /// 设 4MB 是为了"顺手把原图也存了"，超限就只走内存。
  static const int maxEntryBytes = 4 * 1024 * 1024;

  static Directory? _rootDir;
  static Directory? _dirOverride;
  static bool _ready = false;
  static bool _initializing = false;
  static Future<void>? _initFuture;

  /// 已知的条目数（近似：进程启动时不遍历磁盘，LRU 精度到"本次会话"为止）。
  static int _entryCount = 0;

  static bool get isReady => _ready;
  static String? get directoryPath => _rootDir?.path;

  /// 幂等、可并发调用的初始化。失败时保持未就绪（后续调用会再试一次）。
  static Future<void> ensureInitialized() {
    if (_ready) return Future<void>.value();
    return _initFuture ??= _doInit().whenComplete(() => _initFuture = null);
  }

  static Future<void> _doInit() async {
    if (_initializing) return;
    _initializing = true;
    try {
      final base = _dirOverride ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/$dirName');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _rootDir = dir;
      // 冷启动时数一下已有条目，免得第一次写就误判"已满"而立刻淘汰。
      try {
        _entryCount = dir.listSync().whereType<File>().length;
      } catch (_) {
        _entryCount = 0;
      }
      _ready = true;
    } catch (e) {
      debugPrint('ProgressiveDiskCache init failed: $e');
      _rootDir = null;
      _ready = false;
    } finally {
      _initializing = false;
    }
  }

  static File? _file(String url) {
    final dir = _rootDir;
    if (dir == null) return null;
    return File('${dir.path}/${stableHash(url)}.img');
  }

  /// 读一条缓存。命中返回字节，未就绪/未命中/出错都返回 null。
  static Future<Uint8List?> load(String url) async {
    if (!_ready) await ensureInitialized();
    final f = _file(url);
    if (f == null) return null;
    try {
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return null;
      _touch(f);
      return bytes;
    } catch (e) {
      debugPrint('ProgressiveDiskCache.load failed: $e');
      return null;
    }
  }

  /// 写一条缓存。空字节/超限/未就绪/写失败都安静跳过——永不抛。
  static Future<void> put(String url, Uint8List bytes) async {
    if (!_ready) await ensureInitialized();
    if (bytes.isEmpty || bytes.length > maxEntryBytes) return;
    final f = _file(url);
    if (f == null) return;
    try {
      await f.writeAsBytes(bytes, flush: false);
      _entryCount++;
      _evictIfNeeded();
    } catch (e) {
      debugPrint('ProgressiveDiskCache.put failed: $e');
    }
  }

  /// 淘汰：超过 [maxEntries] 就删最老的。
  ///
  /// 用文件的最后修改时间当 LRU 时钟（读缓存时 [load] 已经 touch 过）。
  static void _evictIfNeeded() {
    if (_entryCount <= maxEntries) return;
    final dir = _rootDir;
    if (dir == null) return;
    try {
      final files = dir.listSync().whereType<File>().toList()
        ..sort((a, b) {
          final am = a.lastModifiedSync();
          final bm = b.lastModifiedSync();
          return am.compareTo(bm);
        });
      var over = _entryCount - maxEntries;
      for (final f in files) {
        if (over-- <= 0) break;
        f.deleteSync();
        _entryCount--;
      }
    } catch (e) {
      debugPrint('ProgressiveDiskCache evict failed: $e');
    }
  }

  /// 读命中时把 mtime 推到"现在"，作为 LRU 的访问序。
  static void _touch(File f) {
    try {
      f.setLastModifiedSync(DateTime.now());
    } catch (_) {
      // 改不了 mtime 不影响正确性，只是 LRU 退化成按写入序淘汰。
    }
  }

  /// 清空磁盘缓存（设置页「清除数据」用）。
  static Future<void> clearAll() async {
    final dir = _rootDir;
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      _entryCount = 0;
    } catch (e) {
      debugPrint('ProgressiveDiskCache.clearAll failed: $e');
    }
  }

  // ─── 测试钩子 ─────────────────────────────────────────────────────────────

  @visibleForTesting
  static void resetForTests() {
    _ready = false;
    _rootDir = null;
    _dirOverride = null;
    _entryCount = 0;
    _initFuture = null;
    _initializing = false;
  }

  /// 测试用：指定缓存根目录，等价于 path_provider 返回该目录。
  @visibleForTesting
  static Future<void> debugUseDirectory(Directory dir) async {
    _dirOverride = dir;
    await ensureInitialized();
  }
}

/// 部分解码节流的图片 provider。
///
/// 相等性按 URL 判定，因此仍然命中 Flutter 的 ImageCache：滚回来时直接复用
/// 已经解码好的完整图，不会重新下载。
///
/// [retry] 是"第几次尝试"的代号，默认 0。它只参与相等性判定，**不改请求
/// URL**：点「重试」时把代号加一，等于换了一个缓存 key，于是 ImageCache
/// 不会再把上一次那个已经 `reportError` 过的 completer 交回来（按 URL 判等
/// 时就会，那样按钮点了也没反应——重试了个寂寞），而是重新走一遍 `loadImage`
/// 真正再下 一次。
class ProgressiveImageProvider extends ImageProvider<ProgressiveImageProvider> {
  ProgressiveImageProvider(
    this.url, {
    this.retry = 0,
    this.throttle,
    this.timeout = const Duration(seconds: 20),
  });

  final String url;

  /// 第几次尝试（重试次数），只用于参与缓存 key 的判定。
  final int retry;

  final ProgressiveDecodeThrottle? throttle;
  final Duration timeout;

  @override
  Future<ProgressiveImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<ProgressiveImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    ProgressiveImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return _ProgressiveImageCompleter(
      url: key.url,
      decode: decode,
      throttle: key.throttle ?? ProgressiveDecodeThrottle(),
      timeout: key.timeout,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProgressiveImageProvider &&
      other.url == url &&
      other.retry == retry;

  @override
  int get hashCode => Object.hash(ProgressiveImageProvider, url, retry);

  @override
  String toString() => 'ProgressiveImageProvider("$url", retry: $retry)';
}

class _ProgressiveImageCompleter extends ImageStreamCompleter {
  _ProgressiveImageCompleter({
    required this.url,
    required this.decode,
    required this.throttle,
    required this.timeout,
  }) {
    _pump();
  }

  final String url;
  final ImageDecoderCallback decode;
  final ProgressiveDecodeThrottle throttle;
  final Duration timeout;

  // 自增长缓冲：避免每解码一次就整体复制一遍（BytesBuilder.toBytes()）。
  Uint8List _buf = Uint8List(64 * 1024);
  int _len = 0;

  void _append(List<int> data) {
    if (_len + data.length > _buf.length) {
      var cap = _buf.length * 2;
      while (cap < _len + data.length) {
        cap *= 2;
      }
      final next = Uint8List(cap);
      next.setRange(0, _len, _buf);
      _buf = next;
    }
    _buf.setRange(_len, _len + data.length, data);
    _len += data.length;
  }

  /// 已收到字节的视图（零拷贝）。
  Uint8List get _view => Uint8List.view(_buf.buffer, 0, _len);

  Future<void> _pump() async {
    // 先问磁盘：命中就只解码，不再经 ECH 下一次。墙内这是"秒出"与"等好几秒"
    // 的分界，所以放在最前面。
    final cached = await ProgressiveDiskCache.load(url);
    if (cached != null) {
      // 直接用 cached 本身解码，**不塞进 _buf**：_view 是按
      // `_buf.buffer, 0` 取视图的，而磁盘读回的字节不保证 offsetInBytes 为0
      // （File.readAsBytes 一般是 0，但不能赌），偏移非0 时 _view 会取错段。
      // 磁盘命中直接解，不进 _buf，也就不涉及逐块追加的那套逻辑。
      await _decodeAndEmit(cached, isFinal: true);
      return;
    }

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      // 上游没给 Content-Length 时（分块编码）expectedTotalBytes 为 null，
      // 进度条会显示成不确定态。
      final total = response.contentLength > 0 ? response.contentLength : null;

      // 卡住不动 30 秒就放弃：connectionTimeout 只管建连，管不了中途断流。
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        _append(chunk);
        // 喂给 Image 的 loadingBuilder（进度条用它）。
        reportImageChunkEvent(ImageChunkEvent(
          cumulativeBytesLoaded: _len,
          expectedTotalBytes: total,
        ));

        final now = DateTime.now();
        if (throttle.shouldDecode(_len, now)) {
          throttle.mark(_len, now);
          await _decodeAndEmit(_view, isFinal: false);
        }
      }

      if (_len == 0) {
        throw HttpException('响应为空', uri: Uri.parse(url));
      }

      // 完整数据必须解一次：部分解码成功不代表最终一定成功（例如 PNG 只在
      // 最后才可解），失败时这里才报错给 errorBuilder。
      final decoded = await _decodeAndEmit(_view, isFinal: true);
      // **只有完整字节解出来了才落盘**。PNG 这类不支持部分解码的格式，
      // 在中途解码失败很正常——把残缺字节写进缓存，下次命中就是一个
      // "解不开的缓存"，而且因为它不抛错，卡片会一直白着。宁可下次重下。
      if (decoded) {
        unawaited(ProgressiveDiskCache.put(url, _view));
      }
    } catch (e, s) {
      reportError(exception: e, stack: s);
    } finally {
      client.close(force: true);
    }
  }

  /// 解一次并交给框架。返回**是否真的解出了图**。
  ///
  /// 落盘与否要用返回值判断：中途部分解码成功不代表最终一定成功，用
  /// "调了没抛" 当成功会把残缺字节写进磁盘缓存（PNG 在中途必然抛）。
  Future<bool> _decodeAndEmit(Uint8List bytes, {required bool isFinal}) async {
    if (bytes.isEmpty) return false;
    ui.Codec? codec;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      codec = await decode(buffer);
      final frame = await codec.getNextFrame();
      // setImage 会把上一帧交还给框架释放，这里不要自己 dispose。
      setImage(ImageInfo(image: frame.image, scale: 1.0));
      return true;
    } catch (e, s) {
      // 数据还不够：baseline JPEG / PNG 在数据不完整时会直接解失败，静默等
      // 下一块即可。只有"完整数据也解不出来"才是真的错误。
      if (isFinal) reportError(exception: e, stack: s);
      return false;
    } finally {
      codec?.dispose();
    }
  }
}
