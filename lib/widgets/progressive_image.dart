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

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

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

/// 逐块解码的图片 provider。
///
/// 相等性按 URL 判定，因此仍然命中 Flutter 的 ImageCache：滚回来时直接复用
/// 已经解码好的完整图，不会重新下载。
class ProgressiveImageProvider extends ImageProvider<ProgressiveImageProvider> {
  ProgressiveImageProvider(
    this.url, {
    this.throttle,
    this.timeout = const Duration(seconds: 20),
  });

  final String url;
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
      other is ProgressiveImageProvider && other.url == url;

  @override
  int get hashCode => Object.hash(ProgressiveImageProvider, url);

  @override
  String toString() => 'ProgressiveImageProvider("$url")';
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

  /// 已被框架释放（卡片滚出视口 / 页面被 pop）。
  ///
  /// 必要性：`_pump` 在构造函数里就启动了，`Image` 被移出树后最后一个 listener
  /// 移除会调 `dispose()`，但 HTTP 下载不会因此停 —— 它会一直跑到 20s 超时或
  /// 响应结束。详情页里有十几张图同时构建，用户按返回键后这些下载还在继续跑，
  /// 在墙内 ECH 链路上每张 10-30s，白白吃带宽。
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

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
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      if (_disposed) return;
      final request = await client.getUrl(Uri.parse(url));
      if (_disposed) return;
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      // 上游没给 Content-Length 时（分块编码）expectedTotalBytes 为 null，
      // 进度条会显示成不确定态。
      final total = response.contentLength > 0 ? response.contentLength : null;

      // 卡住不动 30 秒就放弃：connectionTimeout 只管建连，管不了中途断流。
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (_disposed) break; // 已经没人在看了，别继续吃带宽。
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
          if (_disposed) break;
        }
      }

      if (_disposed) return;

      if (_len == 0) {
        throw HttpException('响应为空', uri: Uri.parse(url));
      }

      // 完整数据必须解一次：部分解码成功不代表最终一定成功（例如 PNG 只在
      // 最后才可解），失败时这里才报错给 errorBuilder。
      await _decodeAndEmit(_view, isFinal: true);
    } catch (e, s) {
      if (_disposed) return;
      reportError(exception: e, stack: s);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _decodeAndEmit(Uint8List bytes, {required bool isFinal}) async {
    if (bytes.isEmpty || _disposed) return;
    ui.Codec? codec;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      codec = await decode(buffer);
      final frame = await codec.getNextFrame();
      // 解码期间被释放（卡片滚出视口）：帧已经没人在看，别再去 setImage。
      if (_disposed) return;
      // setImage 会把上一帧交还给框架释放，这里不要自己 dispose。
      setImage(ImageInfo(image: frame.image, scale: 1.0));
    } catch (e, s) {
      // 数据还不够：baseline JPEG / PNG 在数据不完整时会直接解失败，静默等
      // 下一块即可。只有"完整数据也解不出来"才是真的错误。
      if (isFinal && !_disposed) reportError(exception: e, stack: s);
    } finally {
      codec?.dispose();
    }
  }
}
