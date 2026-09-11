// video_failure.dart
// 视频播放失败的分类与文案。
//
// 单独抽出来是为了**能被单元测试覆盖**：这里的分支决定了用户看到什么，
// 以及「重试」要不要先释放其它播放器 —— 解码器类失败必须先腾位，否则重试
// 必然以同样的错误再失败一次，用户只会得出"重试没用"的结论。

/// 代理没起来。**不能**退回原始 URL：墙内直连 `*.twimg.com` 必死（实测 000），
/// 那样只是把一个失败换成另一个失败，还让用户看不出原因。
class VideoProxyNotReady implements Exception {
  const VideoProxyNotReady();

  @override
  String toString() => 'ECH 代理未就绪（端口为空：还没启动、启动失败或刚重启）';
}

class VideoFailure {
  VideoFailure._();

  /// 代理未就绪。用它而**不是**字符串匹配：文案会改，类型不会。
  static bool isProxyNotReady(Object e) => e is VideoProxyNotReady;

  /// 解码器类失败。
  ///
  /// 真实报错长这样（用户实测）：
  /// ```
  /// PlatformException(VideoError, Video player had error v.i:
  /// MediaCodecVideoRenderer error, index=0, format=Format(1, null, video/mp4,
  /// video/avc, avc1.640020, 1891376, und, [1280, 720, 60.0, ...]),
  /// format_supported=YES, null, null)
  /// ```
  /// 关键在 `format_supported=YES`：**格式本身是支持的**，报错来自 MediaCodec，
  /// 也就是拿不到空闲的硬件解码器（Android 上 AVC 硬解实例常见只有 2~4 个，
  /// 720p60 High profile 往往只吃得下 2 个），或者该编码在本机不可用。
  static bool isCodecError(Object e) {
    final s = '$e';
    return s.contains('MediaCodec') ||
        s.contains('format_supported') ||
        s.contains('CodecException');
  }

  /// 取数据失败（代理/链路），不是解码器问题。
  static bool isNetworkError(Object e) {
    final s = '$e';
    return s.contains('Source error') ||
        s.contains('HttpDataSource') ||
        s.contains('Unable to connect') ||
        s.contains('Failed to connect') ||
        s.contains('Connection reset') ||
        s.contains('SocketException');
  }

  /// 一句能行动的话。技术细节留给「详情」按钮与日志。
  ///
  /// 判定顺序有讲究：**先判代理、再判解码器**。解码器那条会引导用户点重试
  /// （重试会先腾解码器），而代理没起来时点多少次都是白点，得先说清楚。
  static String humanize(Object e) {
    if (isProxyNotReady(e)) {
      return 'ECH 代理未就绪。等代理启动后点重试。';
    }
    if (isCodecError(e)) {
      return '解码器不够用：本机同时能解码的视频数有限（或该视频编码不被支持）。\n'
          '点重试会先释放其它视频再试。';
    }
    if (isNetworkError(e)) {
      return '取不到视频数据（代理或链路问题）。点重试，仍失败请到设置页反馈。';
    }
    return '视频加载失败。点重试，仍失败请到设置页反馈。';
  }
}
