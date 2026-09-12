// decoder_policy_test.dart
// 解码调度策略：失败分类 + 上限参数。
//
// **发现背景**：v0.5.13 给 video_player_android fork 开了软解回退（
// `setEnableDecoderFallback(true)`），media3 从此把"硬解实例被占满"在播放器
// 内部消化 —— 旧的"codec 报错 → 降档 + 重排 ×3"失去了信号来源，继续用只会
// 在墙内慢链路上重烧 moov 下载。这个测试锁住新语义：**能报上来的解码类错误
// 一律 failFast**，只有网络/代理类还允许一次自动重试。上限参数（1~3、连击 4）
// 也被锁住 —— 它们是按"最坏情况全在软解"定的，改之前必须想清楚 CPU 预算。

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/decode_budget.dart';
import 'package:twitter_pic_flutter/video/decoder_policy.dart';

void main() {
  // 线上实测的两条原文（见 video_failure_test.dart），一条"格式支持但拿不到
  // 解码器"，一条"规格超出解码器能力"。fork 之后**两条都不该再触发重排**。
  const kRealBusyCodecError =
      'PlatformException(VideoError, Video player had error v.i: '
      'MediaCodecVideoRenderer error, index=0, format=Format(1, null, video/mp4, '
      'video/avc, avc1.640020, 1891376, und, [1280, 720, 60.0, ...]), '
      'format_supported=YES, null, null)';
  const kRealUnsupportedFormat =
      'PlatformException(VideoError, ... MediaCodecVideoRenderer error, '
      'format=Format(1, null, video/mp4, video/avc, avc1.640034, 32516104, und, '
      '[2160, 3840, 60.00103, ...], [-1, -1]), '
      'format_supported=NO_EXCEEDS_CAPABILITIES, null, null)';

  test('软解回退开启后，解码类失败一律 failFast（不再降档重排）', () {
    final p = DecoderPolicy();
    expect(p.classify(kRealBusyCodecError), DecodeFailureAction.failFast,
        reason: 'fork 后还能报上来的 codec 错误 = 软硬解都失败，重排只会重烧下载');
    expect(p.classify(kRealUnsupportedFormat), DecodeFailureAction.failFast);
  });

  test('网络/代理类失败仍允许一次自动重试', () {
    final p = DecoderPolicy();
    expect(
      p.classify('PlatformException Source error: HttpDataSourceIOException'),
      DecodeFailureAction.retryOnce,
    );
    expect(
      p.classify('SocketException: Failed to connect to video-cf.twimg.com'),
      DecodeFailureAction.retryOnce,
    );
  });

  test('上限参数：1~3、连击 4（最坏全软解时的 CPU 约束）', () {
    expect(DecoderPolicy.kFallbackAwareCeiling, 3);
    expect(DecoderPolicy.kSuccessStreakToRaise, 4);

    final p = DecoderPolicy(budget: DecodeBudget(initial: 2, ceiling: 3));
    expect(p.maxConcurrent, 2);
    for (var i = 0; i < 12; i++) {
      p.noteSuccess();
    }
    expect(p.maxConcurrent, 3, reason: '可以涨，但绝不越过软解安全上限');
  });
}
