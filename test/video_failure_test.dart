// video_failure_test.dart
// 视频失败分类的回归测试。
//
// 用例 1 的字符串是**线上实测**（用户报「视频经常加载失败」时贴出来的完整
// PlatformException），它必须被判成"解码器"而不是"网络" —— 这两种的处置完全
// 不同：解码器类重试前要先释放其它播放器（腾解码器槽位），网络类重试只需等一等。

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/video_failure.dart';

/// 用户实测报错（原样保留，不要"美化"）。
const String kRealCodecError =
    'PlatformException(VideoError, Video player had error v.i: '
    'MediaCodecVideoRenderer error, index=0, '
    'format=Format(1, null, video/mp4, video/avc, avc1.640020, 1891376, und, '
    '[1280, 720, 60.0, ColorInfo(Unset color space, Unset color range, '
    'Unset color transfer, false, 8bit Luma, 8bit Chroma)], [-1, -1]), '
    'format_supported=YES, null, null)';

/// 用户实测报错：竖屏 4K@60 H.264 High@5.1（2160×3840，约 498 Mpx/s），
/// 本机硬解解不了。
///
/// `format_supported=NO_EXCEEDS_CAPABILITIES` 是 Media3 `Util.getFormatSupportString`
/// 对 `C.FORMAT_EXCEEDS_CAPABILITIES` 的字符串渲染（"NO" + 原因），**不是**
/// "没有超出能力"。
const String kRealUnsupportedFormat =
    'PlatformException(VideoError, Video player had error v.i: '
    'MediaCodecVideoRenderer error, index=0, '
    'format=Format(1, null, video/mp4, video/avc, avc1.640034, 32516104, und, '
    '[2160, 3840, 60.00103, ColorInfo(Unset color space, Unset color range, '
    'Unset color transfer, false, 8bit Luma, 8bit Chroma)], [-1, -1]), '
    'format_supported=NO_EXCEEDS_CAPABILITIES, null, null)';

void main() {
  test('线上实测的 MediaCodec 报错判为解码器问题', () {
    expect(VideoFailure.isCodecError(kRealCodecError), isTrue);
    // 不能同时被判成网络问题：两者处置不同
    expect(VideoFailure.isNetworkError(kRealCodecError), isFalse);
    expect(VideoFailure.humanize(kRealCodecError), contains('解码器'));
    expect(VideoFailure.humanize(kRealCodecError), contains('重试'));
  });

  test('format_supported=YES 不被新分类吞掉，仍是可重试的解码器争用', () {
    expect(VideoFailure.isUnsupportedFormat(kRealCodecError), isFalse);
    expect(VideoFailure.isCodecError(kRealCodecError), isTrue);
  });

  test('超出解码器能力的格式判为永久失败', () {
    expect(VideoFailure.isUnsupportedFormat(kRealUnsupportedFormat), isTrue);
    // 关键回归锁：绝不能同时判成 isCodecError —— 那样会白跑 3 次重试，
    // 还会 noteCodecFailure 降整个池子的解码器预算、误伤同屏其它视频。
    expect(VideoFailure.isCodecError(kRealUnsupportedFormat), isFalse);
    expect(VideoFailure.isNetworkError(kRealUnsupportedFormat), isFalse);
  });

  test('永久失败的文案说清"重试不会成功"，且不再引导用户点重试', () {
    final msg = VideoFailure.humanize(kRealUnsupportedFormat);
    expect(msg, contains('解码器'));
    expect(msg, contains('不会成功'));
    // 不给"点重试"这种必然失败的引导（文案里说明"重试也不会成功"是对的）
    expect(msg, isNot(contains('点重试')));
    expect(msg, isNot(contains('代理')));
    expect(msg, isNot(contains('取不到视频数据')));
  });

  test('其它 UNSUPPORTED_* 变体同样算永久失败', () {
    for (final msg in <String>[
      '...format_supported=NO_UNSUPPORTED_SUBTYPE, null, null)',
      '...format_supported=NO_UNSUPPORTED_DRM, null, null)',
    ]) {
      expect(VideoFailure.isUnsupportedFormat(msg), isTrue, reason: msg);
      expect(VideoFailure.isCodecError(msg), isFalse, reason: msg);
    }
  });

  test('认不出的失败不误判成永久失败（仍走可重试路径）', () {
    expect(
      VideoFailure.isUnsupportedFormat('some totally unknown failure'),
      isFalse,
    );
  });

  test('代理未就绪的文案优先于其它判断', () {
    const e = VideoProxyNotReady();
    expect(VideoFailure.isProxyNotReady(e), isTrue);
    // 代理没起来时点多少次重试都是白点，必须先说清楚
    expect(VideoFailure.humanize(e), contains('代理未就绪'));
    // 也不能被误判成网络或解码器问题
    expect(VideoFailure.isCodecError(e), isFalse);
    expect(VideoFailure.isNetworkError(e), isFalse);
  });

  test('取数据失败判为网络/链路问题', () {
    for (final msg in <String>[
      'PlatformException(VideoError, Video player had error '
          'androidx.media3.exoplayer.ExoPlaybackException: Source error, null, null)',
      // 原始类名里就带 $（Java 内部类），必须用 raw string：
      // 普通单引号串里 `$HttpDataSourceException` 会被当成插值 → 编译期报
      // undefined_identifier（这条是 CI 抓出来的）。
      r'HttpDataSource$HttpDataSourceException: Unable to connect',
      'SocketException: Connection reset by peer',
    ]) {
      expect(VideoFailure.isNetworkError(msg), isTrue, reason: msg);
      expect(VideoFailure.isCodecError(msg), isFalse, reason: msg);
      expect(VideoFailure.humanize(msg), contains('取不到视频数据'), reason: msg);
    }
  });

  test('认不出的失败给通用文案，不撒谎', () {
    final msg = VideoFailure.humanize('some totally unknown failure');
    expect(msg, contains('视频加载失败'));
    expect(msg, isNot(contains('解码器')));
    expect(msg, isNot(contains('代理未就绪')));
  });

  test('CodecException 也算解码器问题', () {
    expect(
      VideoFailure.isCodecError('MediaCodec.CodecException: error 0x80000000'),
      isTrue,
    );
  });
}
