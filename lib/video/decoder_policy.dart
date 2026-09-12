// decoder_policy.dart
// 解码调度策略（纯逻辑，可单测）：**唯一**知道「我们跑的 video_player_android
// 是开了 decoder fallback 的 fork」这件事的 Dart 代码。
//
// fork 语义（doc/troubleshooting.md 案例 14）：media3 的
// `DefaultRenderersFactory.setEnableDecoderFallback(true)` 让"硬解初始化失败"
// （实例被占满、规格超出硬解能力）在播放器内部就被消化掉 —— 顺延到解码器列表的
// 下一个（软解）。因此我们**能看到的** MediaCodec 类报错，意味着硬解**和**软解
// 都失败了。这直接改变了两个旧结论：
//
//   1. 「撞解码器上限 → 降并发档」不再成立：报错不再是并发信号，降档救不了它，
//      反而把同屏其它卡片白白拖慢。→ 不再调用 `onCodecFailure()`。
//   2. 「降档 + 重排、最多试 3 次」不再成立：每次重排 = 在墙内慢链路上重跑一遍
//      init（取 moov，秒级到 10s 级流量），而成功率≈0。→ 判 failFast，一次都不重排。
//
// 同时上限的**用途**也变了：从"避免撞硬解实例数的报错"变成"约束同时进行的解码
// 负载"（软解吃 CPU，且 media3 静默回退后我们拿不到任何失败信号），所以上限
// 收缩到 `_kFallbackAwareCeiling`，宁可铺封面慢一点，也不要 6 路软解把 CPU 烧满。

import '../utils/decode_budget.dart';
import '../utils/video_failure.dart';

/// 一次初始化失败之后，卡片该做什么。
enum DecodeFailureAction {
  /// 直接落错误卡片：不重排、不自动重试、不动并发预算。
  failFast,

  /// 自动重试一次（网络/链路类，多为一次性抖动）。不降档。
  retryOnce,
}

class DecoderPolicy {
  /// 开了 decoder fallback 之后允许的最大并发解码路数。
  ///
  /// 旧上限（6）的前提是"撞上限会报错 → 可自愈"；fork 之后前提没了（见文件头），
  /// 上限必须按"最坏情况全是软解"来定。低端机同时跑 2~3 路软解就到极限了。
  static const int kFallbackAwareCeiling = 3;

  /// 连续成功几次才 +1。fork 之后"成功"不再证明还有硬解余量（成功的可能正在
  /// 软解），所以上调要比旧版更保守。
  static const int kSuccessStreakToRaise = 4;

  final DecodeBudget budget;

  DecoderPolicy({DecodeBudget? budget})
      : budget = budget ??
            DecodeBudget(
              initial: 2,
              ceiling: kFallbackAwareCeiling,
              successStreakToRaise: kSuccessStreakToRaise,
            );

  /// 当前并发上限。
  int get maxConcurrent => budget.value;

  /// 一次成功（抓到一帧封面 / 完成一次播放初始化）。返回 true 表示上限被上调。
  bool noteSuccess() => budget.onSuccess();

  /// 给一次失败分类。**顺序**：先永久失败（含 codec 类，见文件头），再代理/网络。
  DecodeFailureAction classify(Object e) {
    if (VideoFailure.isUnsupportedFormat(e) || VideoFailure.isCodecError(e)) {
      return DecodeFailureAction.failFast;
    }
    return DecodeFailureAction.retryOnce;
  }
}
