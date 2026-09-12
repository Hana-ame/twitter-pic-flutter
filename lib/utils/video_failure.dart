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

  /// 解码器**争用**类失败：格式本身是支持的，只是拿不到空闲的硬解实例。
  /// **可重试** —— 先释放其它播放器再试，有机会成功。
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
  ///
  /// `NO_EXCEEDS_CAPABILITIES` 那类**不属于**这里（见 [isUnsupportedFormat]）：
  /// 那是本机解码器根本解不了这个规格，重试永远失败，重试还会白降解码器预算。
  static bool isCodecError(Object e) {
    if (isUnsupportedFormat(e)) return false;
    final s = '$e';
    return s.contains('MediaCodec') ||
        s.contains('format_supported') ||
        s.contains('CodecException');
  }

  /// 格式超出本机解码器能力：**永久失败，重试也不会成功**。
  ///
  /// Media3 `MediaCodecVideoRenderer` 只有两种判定（见该类 `handlesFormat`）：
  /// `isFormatSupported ? FORMAT_HANDLED : FORMAT_EXCEEDS_CAPABILITIES`。
  /// `Util.getFormatSupportString` 把它们渲染成字符串塞进报错文案：
  /// ```java
  /// FORMAT_HANDLED              -> "YES"
  /// FORMAT_EXCEEDS_CAPABILITIES -> "NO_EXCEEDS_CAPABILITIES"
  /// FORMAT_UNSUPPORTED_DRM      -> "NO_UNSUPPORTED_DRM"
  /// FORMAT_UNSUPPORTED_SUBTYPE  -> "NO_UNSUPPORTED_SUBTYPE"
  /// ```
  /// 注意 `NO_EXCEEDS_CAPABILITIES` 是「NO」+「原因」的拼接，**不是**
  /// "没有超出能力"。`C.java` 对 `FORMAT_EXCEEDS_CAPABILITIES` 的定义：
  /// MIME 类型支持，但格式的**属性**（分辨率/帧率）超出底层解码器声明的上限，
  /// "the expected outcome is that playback will fail"。
  ///
  /// 用户实测的一条（2160×3840 竖屏 4K @60fps H.264 High@5.1，约 498 Mpx/s，
  /// 手机 H.264 硬解上限普遍是 4K@60 ≈ 50 Mpx/s）：
  /// ```
  /// format=Format(1, null, video/mp4, video/avc, avc1.640034, 32516104, und,
  /// [2160, 3840, 60.00103, ...], [-1, -1]), format_supported=NO_EXCEEDS_CAPABILITIES
  /// ```
  /// 这里只判字符串，不解析分辨率：`isFormatSupported` 是解码器**静态声明的
  /// 能力**与格式属性的比较，同一台设备上重试必然得到同一个结果。
  static bool isUnsupportedFormat(Object e) {
    final s = '$e';
    return s.contains('EXCEEDS_CAPABILITIES') ||
        s.contains('UNSUPPORTED_DRM') ||
        s.contains('UNSUPPORTED_SUBTYPE') ||
        s.contains('UNSUPPORTED_TYPE');
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
  /// 判定顺序有讲究：**先判代理、再判永久失败、再判解码器**。
  /// 解码器那条会引导用户点重试（重试会先腾解码器），而代理没起来时点多少次
  /// 都是白点、解码器解不了这个规格时点多少次也一模一样，都得先说清楚。
  /// （[isCodecError] 已排除永久失败那类，所以后两条互斥；这里再显式排一次
  /// 是为了让"先排除不可重试"的意图读得出来。）
  static String humanize(Object e) {
    if (isProxyNotReady(e)) {
      return 'ECH 代理未就绪。等代理启动后点重试。';
    }
    if (isUnsupportedFormat(e)) {
      return '这台设备的视频解码器解不了这个视频：编码本身支持，但分辨率/帧率'
          '超出硬解上限。重试也不会成功，可换用支持该规格的设备。\n'
          '（原文保留在下方，反馈时一并带上）';
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
