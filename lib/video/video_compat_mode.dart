// video_compat_mode.dart
// 视频播放兼容模式（纯配置与策略映射 + Android 原生解码器通道与遥测，可单测）。
//
// 背景（flutter/flutter#174026、#185674）：
// 部分 Android 机型（尤以 MediaTek 天玑等 SoC 为甚）在 Media3 下播放宽高不能被
// 16 整除的视频（如 720x1100、848x478、688x1040）时，会因硬件解码器（如
// c2.mtk.avc.decoder）输出 stride 与 Flutter TextureView（Impeller
// ImageReaderSurfaceProducer）纹理采样不匹配，导致画面斜切与绿色斜纹。
//
// 配合 `Hana-ame/video_player_android` fork（2.12.2-fallback.2+）新增的
// `CompatRenderersFactory`、`DecoderTelemetry` 与 `decoder_mode` MethodChannel，
// 提供 1 个标准 + 4 个兼容模式（全部保持流式起播，不强制等整段下完）：
//   0. standard             — 标准模式（auto）：textureView + 全程有硬解就用硬解（失败才回退软解）
//   1. smartSoftware        — 兼容 1：智能软解（smart）：仅宽高非 16 倍数时把软解排前，标准分辨率仍硬解
//   2. platformView         — 兼容 2：原生视图（PlatformView + auto）：原生 SurfaceView 上屏，解码仍硬解优先
//   3. preferSoftware       — 兼容 3：优先软解（prefer_software）：textureView + 软解排前，硬解保留可回退
//   4. platformViewSoftware — 兼容 4：原生视图 + 优先软解（prefer_software）：两者叠加
//
// **核心语义：4 个兼容模式做的都是「重排优先级」，不是「删掉硬解」。**
// 原生侧 `preferSoftwareOrder()` 从 `MediaCodecSelector.DEFAULT` 取**全部**解码器，
// 只把 softwareOnly 的分到前段、硬解的分到后段再拼回去；软解列表为空时原样返回。
// 所以任何模式下软解解不了的格式都仍会回退硬解，不存在"开了兼容反而更解不了"。
// 标准模式与兼容 2 的 `auto` 更是完全不动解码器顺序 —— 正常机型行为与改动前一致。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../services/log_service.dart';

enum VideoCompatMode {
  /// 标准模式（auto）：TextureView + 全程有硬解就用硬解（硬解失败才回退软解）。
  /// 完全不动解码器顺序，并发沿用自适应 DecoderPolicy（1~3）。
  standard,

  /// 兼容 1（智能软解 · smart）：TextureView + 仅对宽或高不能被 16 整除的视频
  /// 把软解排到硬解前面（重排），标准 720p/1080p 仍走硬解。硬解保留可回退。
  smartSoftware,

  /// 兼容 2（原生视图 · PlatformView + auto）：Android 切 PlatformView
  /// （原生 SurfaceView）绕过 Impeller ImageReaderSurfaceProducer 纹理采样；
  /// 解码仍是 auto，有硬解就用硬解，不影响正常机型。
  platformView,

  /// 兼容 3（优先软解 · prefer_software）：保留 TextureView 流畅滚动，
  /// 把软解排到硬解前面（**重排，不删硬解**：软解解不了的格式仍回退硬解），
  /// 并发上限锁定为 1（软解吃 CPU，多路同解互相拖垮）。
  preferSoftware,

  /// 兼容 4（原生视图 + 优先软解 · prefer_software）：同时启用 PlatformView
  /// 与 prefer_software 重排，保持流式起播，并发上限锁定为 1。
  platformViewSoftware,
}

extension VideoCompatModeProps on VideoCompatMode {
  /// 持久化到 storage.json 的稳定键值。
  String get storageKey {
    switch (this) {
      case VideoCompatMode.standard:
        return 'standard';
      case VideoCompatMode.smartSoftware:
        return 'smart_software';
      case VideoCompatMode.platformView:
        return 'platform_view';
      case VideoCompatMode.preferSoftware:
        return 'prefer_software';
      case VideoCompatMode.platformViewSoftware:
        return 'platform_view_software';
    }
  }

  /// 传给 Android `video_player_android` fork 的原生解码模式标识。
  /// 见 `VideoPlayerOptions.DECODER_MODE_*`（`auto` / `smart` / `prefer_software`）。
  /// 注意是 `prefer_software`（软解**排前**、硬解保留）而不是 `software_only`
  /// —— fork 里没有任何一处会过滤掉硬解。
  String get nativeDecoderMode {
    switch (this) {
      case VideoCompatMode.standard:
      case VideoCompatMode.platformView:
        return 'auto';
      case VideoCompatMode.smartSoftware:
        return 'smart';
      case VideoCompatMode.preferSoftware:
      case VideoCompatMode.platformViewSoftware:
        return 'prefer_software';
    }
  }

  /// 设置页与弹窗中的完整标题。
  String get label {
    switch (this) {
      case VideoCompatMode.standard:
        return '标准模式（auto）';
      case VideoCompatMode.smartSoftware:
        return '兼容 1：智能软解（smart）';
      case VideoCompatMode.platformView:
        return '兼容 2：原生视图（PlatformView + auto）';
      case VideoCompatMode.preferSoftware:
        return '兼容 3：优先软解（prefer_software）';
      case VideoCompatMode.platformViewSoftware:
        return '兼容 4：原生视图 + 优先软解（prefer_software）';
    }
  }

  /// 紧凑标签（用于菜单副标题或错误按钮）。
  String get shortLabel {
    switch (this) {
      case VideoCompatMode.standard:
        return '标准';
      case VideoCompatMode.smartSoftware:
        return '智能软解';
      case VideoCompatMode.platformView:
        return '原生视图';
      case VideoCompatMode.preferSoftware:
        return '优先软解';
      case VideoCompatMode.platformViewSoftware:
        return '原生+软解';
    }
  }

  /// 一行摘要：用于菜单副标题、「点按播放」占位文案、诊断报告与日志。
  ///
  /// 与 [shortLabel] 同义但语义分开：那个是按钮上的紧凑标签，将来想把按钮文案
  /// 改短时不该连带改坏日志与反馈包里的可读描述。
  String get summary => shortLabel;

  /// 是否为默认（标准）模式。非默认模式首次启用时记一条日志，方便对反馈包。
  bool get isDefault => this == VideoCompatMode.standard;

  /// 菜单右侧的角标。**按实测效果排序，不是按枚举顺序**：
  ///
  /// 用户实测反馈「软解卡，而且有些视频放不出」，所以软解类模式一律标成
  /// 会掉帧的实验档，把真正零代价的那个（原生视图）顶到「推荐」。
  /// 绿纹/斜切的成因是 Impeller 的 `ImageReaderSurfaceProducer` 按紧排
  /// 假设采样，而硬解输出的 rowStride 按 16 对齐（非 16 倍数分辨率必中招）；
  /// 原生 SurfaceView 上屏时这段纹理路径完全不参与，**硬解照旧**，所以是
  /// 唯一既修画面又不加 CPU 的方案。
  String? get badge {
    switch (this) {
      case VideoCompatMode.standard:
        return null;
      case VideoCompatMode.platformView:
        return '推荐';
      case VideoCompatMode.smartSoftware:
      case VideoCompatMode.preferSoftware:
      case VideoCompatMode.platformViewSoftware:
        return '软解·可能掉帧';
    }
  }

  /// 是否把软解排到了硬解前面。软解吃 CPU，实测在低端机上会明显掉帧，
  /// 所以只在画面确实坏了、且原生视图也救不回来时才建议开。
  bool get cpuHeavy =>
      nativeDecoderMode == 'smart' || nativeDecoderMode == 'prefer_software';

  /// 给用户看的适用场景与取舍说明。
  ///
  /// 措辞有意强调「硬解仍然在列表里」：这几个模式做的都是**重排优先级**
  /// （`CompatRenderersFactory.preferSoftwareOrder`），不是把硬件解码器删掉。
  /// 用户最担心的正是「开了兼容会不会反而变卡/解不了」，所以每条都要说清回退路径。
  String get description {
    switch (this) {
      case VideoCompatMode.standard:
        return '全程有硬解就用硬解（硬解失败才回退软解），不影响正常机型。';
      case VideoCompatMode.smartSoftware:
        return '仅对宽高非 16 倍数的视频把软解排到硬解前面，标准分辨率仍走硬解。';
      case VideoCompatMode.platformView:
        return '改由原生 SurfaceView 上屏，绕过 Impeller 纹理；解码仍是有硬解就用硬解，不影响正常机型。';
      case VideoCompatMode.preferSoftware:
        return '只重排优先级：软解排前、硬解仍留在列表里；绝不硬删硬件解码器，软解解不了时自动回退硬解。';
      case VideoCompatMode.platformViewSoftware:
        return '原生 SurfaceView + 优先软解；同样只重排优先级，绝不硬删硬解，软解解不了时自动回退。';
    }
  }

  /// Android 端是否切换到 PlatformView（原生 SurfaceView）。
  bool get usePlatformView =>
      this == VideoCompatMode.platformView ||
      this == VideoCompatMode.platformViewSoftware;

  /// 无缓存/推导封面时，是否允许在后台自动占解码器抓一帧封面。
  ///
  /// PlatformView 无法被 RepaintBoundary 离屏抓帧（必黑）；优先软解模式并发上限为 1，
  /// 不应在后台抢占唯一解码器；标准与智能软解模式可正常抓帧。
  bool get allowAutoPosterDecode =>
      this == VideoCompatMode.standard ||
      this == VideoCompatMode.smartSoftware;

  /// 播放器初始化完成后是否尝试用 RepaintBoundary 抓帧当封面。
  bool get capturePosterFromPlayer => !usePlatformView;

  /// 是否强制覆盖解码器并发池上限（null 表示遵循自适应 DecoderPolicy）。
  int? get maxConcurrentOverride {
    switch (this) {
      case VideoCompatMode.preferSoftware:
      case VideoCompatMode.platformViewSoftware:
        return 1;
      case VideoCompatMode.standard:
      case VideoCompatMode.smartSoftware:
      case VideoCompatMode.platformView:
        return null;
    }
  }

  /// 当前平台实际传给 `VideoPlayerController` 的 `VideoViewType`。
  ///
  /// Windows 端（`video_player_win`）始终使用 `textureView`，仅 Android
  /// 端按模式切换到 `platformView`。
  VideoViewType effectiveViewType({required bool isAndroid}) {
    if (!isAndroid || !usePlatformView) return VideoViewType.textureView;
    return VideoViewType.platformView;
  }
}

/// 从存储字符串解析 [VideoCompatMode]；兼容旧版键值，未知值安全回退为标准模式。
VideoCompatMode videoCompatModeFromStorage(String? raw) {
  switch (raw?.trim()) {
    case 'smart_software':
      return VideoCompatMode.smartSoftware;
    case 'platform_view':
      return VideoCompatMode.platformView;
    case 'prefer_software':
    case 'software_only':
    case 'software_decode':
    case 'single_decoder':
      return VideoCompatMode.preferSoftware;
    case 'platform_view_software':
    case 'software_platform_view':
    case 'local_file':
      return VideoCompatMode.platformViewSoftware;
    case 'standard':
    default:
      return VideoCompatMode.standard;
  }
}

/// 与 `Hana-ame/video_player_android` fork 同步 Android 原生解码器模式并读取遥测。
///
/// 非 Android 平台或旧版 fork 未注册该通道时安静忽略，不抛异常。
class VideoCompatChannel {
  VideoCompatChannel._();

  static const MethodChannel _channel = MethodChannel(
    'plugins.flutter.dev/video_player_android/decoder_mode',
  );

  static Future<void> apply(VideoCompatMode mode) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<String>(
        'setDecoderMode',
        mode.nativeDecoderMode,
      );
    } on MissingPluginException {
      // 旧版 video_player_android 或测试环境未注册该通道时忽略。
    } catch (e) {
      LogService.recordNote('video.compat', '同步原生解码模式失败: $e');
    }
  }

  /// 查询最近一次 Android Media3 实际初始化的视频解码器摘要（用于日志与反馈包）。
  static Future<String?> getLastDecoderSummary() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getLastDecoderInfo',
      );
      if (raw == null || raw.isEmpty) return null;
      final name = raw['decoderName']?.toString() ?? '-';
      final w = raw['width'];
      final h = raw['height'];
      final mode = raw['decoderMode']?.toString() ?? '-';
      final unaligned = raw['unaligned'] == true;
      final size = (w is int && h is int && w > 0 && h > 0) ? '${w}x$h' : '-';
      return '$name ($size, mode=$mode${unaligned ? ', non-16px' : ''})';
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
