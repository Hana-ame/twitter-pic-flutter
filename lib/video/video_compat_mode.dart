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
// 提供「默认 + 4 种正交兼容模式」（全部保持流式起播，不强制等整段下完）：
//   0. standard             — 标准模式（默认）：TextureView + 硬解优先/软解回退（auto）
//   1. smartSoftware        — 兼容 1：智能软解（推荐）：TextureView + 非 16 对齐自动优先软解（smart）
//   2. platformView         — 兼容 2：原生视图（硬解）：Android SurfaceView + 硬解优先（auto）
//   3. preferSoftware         — 兼容 3：优先软解：TextureView + 全部视频优先软解（software_only）+ 单路
//   4. platformViewSoftware — 兼容 4：终极兜底：Android SurfaceView + 优先软解（software_only）+ 单路

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../services/log_service.dart';

enum VideoCompatMode {
  /// 标准模式（默认）：TextureView + 硬解优先（失败回退软解）+ 并发池 1~3。
  standard,

  /// 兼容 1（智能软解 · 推荐）：TextureView + 仅对宽或高不能被 16 整除的视频
  /// 优先使用软件解码（仍保留硬解回退），标准 720p/1080p 仍保持硬解省电。
  smartSoftware,

  /// 兼容 2（原生视图 · 硬解）：Android 切 PlatformView（原生 SurfaceView）绕过
  /// Flutter Impeller ImageReaderSurfaceProducer 纹理采样，同时保留硬解。
  platformView,

  /// 兼容 3（优先软解）：保留 TextureView 流畅滚动，Android 全部视频严格走
  /// `MediaCodecInfo.preferSoftware` 软解（不静默回退到坏硬解），并发上限锁定为 1。
  preferSoftware,

  /// 兼容 4（原生视图 + 优先软解 · 终极兜底）：同时切断 Impeller 纹理路径与厂商
  /// 硬解器，保持流式起播，并发上限锁定为 1。
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
  /// 见 `VideoPlayerOptions.DECODER_MODE_*`（`auto` / `smart` / `software_only`）。
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
        return '标准模式（默认）';
      case VideoCompatMode.smartSoftware:
        return '兼容 1：智能软解（非 16 对齐自动软解·推荐）';
      case VideoCompatMode.platformView:
        return '兼容 2：原生视图（绕过 Impeller 纹理）';
      case VideoCompatMode.preferSoftware:
        return '兼容 3：优先软解（优先软解 + 保留硬解回退）';
      case VideoCompatMode.platformViewSoftware:
        return '兼容 4：原生视图 + 优先软解（终极兜底）';
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

  /// 给用户看的适用场景与取舍说明。
  String get description {
    switch (this) {
      case VideoCompatMode.standard:
        return 'TextureView + 硬解优先（失败回退软解），正常设备流畅度与功耗最佳。';
      case VideoCompatMode.smartSoftware:
        return '仅对宽高非 16 倍数的视频优先软解（仍保留硬解回退），标准 720p/1080p 仍走硬解，兼顾省电与防斜纹。';
      case VideoCompatMode.platformView:
        return 'Android 改用原生 SurfaceView 渲染，绕过 Impeller 纹理 stride 花屏，仍保留硬解。';
      case VideoCompatMode.preferSoftware:
        return '保留 TextureView 流畅滚动，全部视频优先使用软件解码器（仍保留硬解回退），限制单路并发。';
      case VideoCompatMode.platformViewSoftware:
        return '同时启用原生 SurfaceView 与优先软件解码（单路流式播放），彻底避开渲染层与硬解器缺陷。';
    }
  }

  /// Android 端是否切换到 PlatformView（原生 SurfaceView）。
  bool get usePlatformView =>
      this == VideoCompatMode.platformView ||
      this == VideoCompatMode.platformViewSoftware;

  /// 无缓存/推导封面时，是否允许在后台自动占解码器抓一帧封面。
  ///
  /// PlatformView 无法被 RepaintBoundary 离屏抓帧（必黑）；全软解模式并发上限为 1，
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
