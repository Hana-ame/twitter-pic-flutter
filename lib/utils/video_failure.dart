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

  // ─── HTTP 状态码 ──────────────────────────────────────────────────────────
  //
  // fork `video_player_android` 2.12.2-fallback.3 起，ExoPlayer 的报错里带上了
  // 结构化字段（见该仓库 `PlaybackErrorReport.java`）：
  //
  //   PlatformException(VideoError, Video player had error v.j: Source error
  //     [code=2004 name=ERROR_CODE_IO_BAD_HTTP_STATUS http=403
  //      httpMessage="Forbidden" uri=http://127.0.0.1:8123/media/xxx.mp4
  //      decoder=c2.android.avc.decoder decoderMode=auto
  //      cause=InvalidResponseCodeException: Invalid response code: 403],
  //     null, null)
  //
  // 在此之前 `error.toString()` 只有 `类名: Source error`，`errorCode` 与 HTTP
  // 状态码**全被丢掉** —— 403、404、超时、连接重置在 App 里长得一模一样，只能
  // 统一提示「取不到视频数据」：用户不知道能不能重试，我们也定位不到。
  //
  // 这两条正则只认自己发出的字段名（`code=` / `http=`），旧版本插件发来的消息
  // 里没有它们，自然退化成 null —— 向后兼容，不需要版本判断。

  static final RegExp _kHttpStatus = RegExp(r'\bhttp=(\d{3})\b');
  static final RegExp _kMedia3ErrorCode = RegExp(r'\bcode=(-?\d+)\b');

  /// 上游回的 HTTP 状态码。连接层失败（超时/重置）与解码失败时为 null。
  static int? httpStatusOf(Object e) {
    final m = _kHttpStatus.firstMatch('$e');
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// Media3 `PlaybackException.errorCode`（`2000` 起是 IO 类，`5xxx` 是解码类）。
  /// 只在需要看细分原因时用；用户能懂的判据是 [httpStatusOf]。
  static int? errorCodeOf(Object e) {
    final m = _kMedia3ErrorCode.firstMatch('$e');
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// 4xx：请求本身被上游拒绝。**同一个 URL 重试必然得到同一个状态码**，
  /// 所以既不该自动重试，也不该在文案里引导用户点重试。
  static bool isClientHttpError(Object e) {
    final s = httpStatusOf(e);
    return s != null && s >= 400 && s <= 499;
  }

  /// 401/403：上游拒绝。多为媒体链接已过期/需要重新签发，或代理转发时的
  /// 来源信息（Referer/UA）被 CDN 拒识。
  static bool isHttpForbidden(Object e) {
    final s = httpStatusOf(e);
    return s == 401 || s == 403;
  }

  /// 404/410：媒体已被删除或链接失效。**永久失败**。
  static bool isHttpMissing(Object e) {
    final s = httpStatusOf(e);
    return s == 404 || s == 410;
  }

  /// 5xx：上游自己出错，一般是临时的，值得重试一次。
  static bool isHttpServerError(Object e) {
    final s = httpStatusOf(e);
    return s != null && s >= 500 && s <= 599;
  }

  /// 连接超时（根本没拿到状态码）。
  static bool isTimeout(Object e) {
    // PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT
    if (errorCodeOf(e) == 2001) return true;
    final s = '$e';
    return s.contains('timeout') ||
        s.contains('Timeout') ||
        s.contains('timed out');
  }

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
  ///
  /// **软解回退的交互**：Android 端的 fork `video_player_android` 已开启
  /// `setEnableDecoderFallback(true)`（见 pubspec 的 dependency_overrides）；硬解解不了
  /// 会先自动退到软解，只有**软解也解不了**（或本机没有该编码的软解）时才会真正失败。
  /// 所以本类判"永久失败、不该重试"的结论依然成立。
  static bool isUnsupportedFormat(Object e) {
    final s = '$e';
    return s.contains('EXCEEDS_CAPABILITIES') ||
        s.contains('UNSUPPORTED_DRM') ||
        s.contains('UNSUPPORTED_SUBTYPE') ||
        s.contains('UNSUPPORTED_TYPE');
  }

  /// 取数据失败（代理/链路），不是解码器问题。
  static bool isNetworkError(Object e) {
    // 4xx 是终局，不归"链路抖动"：说成抖动会诱导用户反复点一个必然失败的重试。
    if (isClientHttpError(e)) return false;
    final s = '$e';
    return s.contains('Source error') ||
        s.contains('ERROR_CODE_IO_') ||
        s.contains('HttpDataSource') ||
        s.contains('Unable to connect') ||
        s.contains('Failed to connect') ||
        s.contains('Connection reset') ||
        s.contains('SocketException');
  }

  /// 一句能行动的话。技术细节留给「详情」按钮与日志。
  ///
  /// 判定顺序有讲究：**先判代理、再判永久失败、再判解码器、再判 HTTP 状态码**。
  /// 解码器那条会引导用户点重试（重试会先腾解码器），而代理没起来时点多少次
  /// 都是白点、解码器解不了这个规格时点多少次也一模一样，都得先说清楚。
  /// HTTP 状态码必须排在 [isNetworkError] **之前**：403/404 的报错原文里也带
  /// `Source error`，放到后面会被"取不到视频数据"吞掉，把终局失败说成链路抖动。
  /// （[isCodecError] 已排除永久失败那类，所以后两条互斥；这里再显式排一次
  /// 是为了让"先排除不可重试"的意图读得出来。）
  static String humanize(Object e) {
    if (isProxyNotReady(e)) {
      return 'ECH 代理未就绪。等代理启动后点重试。';
    }
    if (isUnsupportedFormat(e)) {
      return '这台设备的视频解码器解不了这个视频：编码本身支持，但分辨率/帧率'
          '超出硬解上限，且软解回退也没成功。重试不会成功，可换用支持该规格的设备。\n'
          '（原文保留在下方，反馈时一并带上）';
    }
    if (isCodecError(e)) {
      // fork 开了软解回退之后，能报上来的 codec 错误意味着硬解**和**软解都失败，
      // 这已经不是"并发不够、等等就好"——卡片侧不再重试（见 decoder_policy.dart）。
      return '解码器不够用：本机同时能解码的视频数有限（或该视频编码不被支持）。\n'
          '（已开启软解回退仍报此错 = 软硬解都不行；点重试只是重烧一遍下载。）';
    }

    // ─── HTTP 状态码：到这一步才知道到底是"被拒""没了"还是"墙抖" ───────────
    final status = httpStatusOf(e);
    if (status != null) {
      if (isHttpForbidden(e)) {
        return '上游拒绝了这次请求（HTTP $status）。常见原因是媒体链接已过期，'
            '或代理转发时被 CDN 拒识。\n'
            '点重试；仍不行请到设置页反馈，把下方详情里的 `uri` 与 `http=$status` 一起带上。';
      }
      if (isHttpMissing(e)) {
        return '这个视频已被删除或链接失效（HTTP $status）。重试不会成功。';
      }
      if (isHttpServerError(e)) {
        return '上游服务器出错（HTTP $status），一般是临时的。点重试。';
      }
      if (isClientHttpError(e)) {
        return '上游拒绝了这次请求（HTTP $status）。重试同一个链接不会成功。';
      }
    }
    if (isTimeout(e)) {
      return '连接超时（没拿到任何响应，多为墙内链路抖动）。点重试。';
    }

    if (isNetworkError(e)) {
      return '取不到视频数据（代理或链路问题）。点重试，仍失败请到设置页反馈。';
    }
    return '视频加载失败。点重试，仍失败请到设置页反馈。';
  }
}
