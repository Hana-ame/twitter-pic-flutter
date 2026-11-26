// video_compat_mode_test.dart
// 视频播放兼容模式：配置解析、平台视图与原生解码映射、StorageService 持久化与解码池单路限制。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';
import 'package:twitter_pic_flutter/utils/decode_budget.dart';
import 'package:twitter_pic_flutter/video/decoder_policy.dart';
import 'package:twitter_pic_flutter/video/video_compat_mode.dart';
import 'package:twitter_pic_flutter/video/video_decoder_pool.dart';
import 'package:video_player/video_player.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// 池子的最小假用户：永远"缺封面、在视口内、没在播"。
///
/// 这里刻意不暴露 `visible` / `playing` 之类的可调参数 —— 本文件只验证并发上限，
/// 从不需要把它们设成别的值；留着可选参数就是 `unused_element_parameter`，而它
/// 是 **warning 级**（`flutter analyze --no-fatal-infos` 不豁免 warning）。
class _FakeSlotUser implements DecoderSlotUser {
  int grantedCount = 0;
  int revokedCount = 0;

  @override
  bool get slotMounted => true;
  @override
  bool get slotNeedsPoster => true;
  @override
  bool get slotVisibleNow => true;
  @override
  bool get slotIsPlaying => false;
  @override
  bool get slotHasPoster => false;
  @override
  void onSlotGranted() => grantedCount++;
  @override
  void onSlotRevoked() => revokedCount++;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('video_compat_mode_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    StorageService.resetForTests();
    await StorageService.ensureInitialized();
  });

  tearDown(() async {
    StorageService.resetForTests();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // 已删除
    }
  });

  group('VideoCompatMode 策略定义（方案 A）', () {
    test('storageKey 可无损 round-trip；默认与旧键一律回退标准模式（auto）', () {
      for (final mode in VideoCompatMode.values) {
        expect(videoCompatModeFromStorage(mode.storageKey), mode);
      }
      // 旧键来自 v0.7.x 的"单路软解/先下后播"实验，语义与 prefer_software 不等价
      // 且实测掉帧明显 —— 升级上来的用户必须回到 auto，而不是永久停在最差档位。
      expect(videoCompatModeFromStorage('software_only'),
          VideoCompatMode.standard);
      expect(videoCompatModeFromStorage('software_decode'),
          VideoCompatMode.standard);
      expect(videoCompatModeFromStorage('single_decoder'),
          VideoCompatMode.standard);
      expect(videoCompatModeFromStorage('software_platform_view'),
          VideoCompatMode.standard);
      expect(videoCompatModeFromStorage('local_file'),
          VideoCompatMode.standard);
      expect(videoCompatModeFromStorage(null), VideoCompatMode.standard);
      expect(videoCompatModeFromStorage(''), VideoCompatMode.standard);
      expect(videoCompatModeFromStorage('  '), VideoCompatMode.standard);
      expect(videoCompatModeFromStorage('unknown_mode'),
          VideoCompatMode.standard);
    });

    test('默认档位是标准模式（auto）：硬解优先，且是唯一的默认值', () {
      // 用户明确要求"默认选项必须是 auto（硬解在前的那个）"，这里把三件事一起锁住：
      //   ① 空存储 → standard；② standard 的原生解码模式是 auto；
      //   ③ standard 的分槽策略不受软解单路限制影响。
      expect(videoCompatModeFromStorage(null), VideoCompatMode.standard);
      expect(VideoCompatMode.standard.nativeDecoderMode, 'auto');
      expect(VideoCompatMode.standard.isDefault, isTrue);
      expect(VideoCompatMode.standard.cpuHeavy, isFalse);
      expect(VideoCompatMode.standard.maxConcurrentOverride, isNull);
      for (final mode in VideoCompatMode.values) {
        if (mode != VideoCompatMode.standard) {
          expect(mode.isDefault, isFalse, reason: '默认档只能有一个');
        }
      }
    });

    test('设置页说明一律一行：description 不超过 20 个字符且不含换行', () {
      for (final mode in VideoCompatMode.values) {
        final d = mode.description;
        expect(d.contains('\n'), isFalse, reason: '${mode.name} 的说明出现了换行');
        expect(d.length, lessThanOrEqualTo(20),
            reason: '${mode.name} 的说明过长（${d.length} 字）：$d');
      }
    });

    test('软解解码器名识别（只影响日志里那一个标记）', () {
      // 实测机型：天玑的 c2.mtk.avc.decoder 是硬解，c2.android.avc.decoder 是软解。
      expect(isSoftwareDecoderName('c2.mtk.avc.decoder'), isFalse);
      expect(isSoftwareDecoderName('c2.qti.avc.decoder'), isFalse);
      expect(isSoftwareDecoderName('OMX.qcom.video.decoder.avc'), isFalse);
      expect(isSoftwareDecoderName('c2.android.avc.decoder'), isTrue);
      expect(isSoftwareDecoderName('OMX.google.h264.decoder'), isTrue);
      expect(isSoftwareDecoderName('c2.android.sw.avc.decoder'), isTrue);
      expect(isSoftwareDecoderName(null), isFalse);
      expect(isSoftwareDecoderName('-'), isFalse);
      expect(isSoftwareDecoderName(''), isFalse);
    });

    test('Android 端按模式切换视图类型，非 Android 始终回退 TextureView', () {
      expect(
        VideoCompatMode.standard.effectiveViewType(isAndroid: true),
        VideoViewType.textureView,
      );
      expect(
        VideoCompatMode.smartSoftware.effectiveViewType(isAndroid: true),
        VideoViewType.textureView,
      );
      expect(
        VideoCompatMode.platformView.effectiveViewType(isAndroid: true),
        VideoViewType.platformView,
      );
      expect(
        VideoCompatMode.preferSoftware.effectiveViewType(isAndroid: true),
        VideoViewType.textureView,
      );
      expect(
        VideoCompatMode.platformViewSoftware.effectiveViewType(isAndroid: true),
        VideoViewType.platformView,
      );

      for (final mode in VideoCompatMode.values) {
        expect(
          mode.effectiveViewType(isAndroid: false),
          VideoViewType.textureView,
          reason: 'Windows/非 Android 端不支持 PlatformView，必须保持 textureView',
        );
      }
    });

    test('各模式原生解码器映射、抓帧与单路并发语义正确', () {
      expect(VideoCompatMode.standard.nativeDecoderMode, 'auto');
      expect(VideoCompatMode.standard.allowAutoPosterDecode, isTrue);
      expect(VideoCompatMode.standard.capturePosterFromPlayer, isTrue);
      expect(VideoCompatMode.standard.maxConcurrentOverride, isNull);

      expect(VideoCompatMode.smartSoftware.nativeDecoderMode, 'smart');
      expect(VideoCompatMode.smartSoftware.allowAutoPosterDecode, isTrue);
      expect(VideoCompatMode.smartSoftware.capturePosterFromPlayer, isTrue);
      expect(VideoCompatMode.smartSoftware.maxConcurrentOverride, isNull);

      expect(VideoCompatMode.platformView.nativeDecoderMode, 'auto');
      expect(VideoCompatMode.platformView.allowAutoPosterDecode, isFalse);
      expect(VideoCompatMode.platformView.capturePosterFromPlayer, isFalse);
      expect(VideoCompatMode.platformView.maxConcurrentOverride, isNull);

      expect(VideoCompatMode.preferSoftware.nativeDecoderMode, 'prefer_software');
      expect(VideoCompatMode.preferSoftware.allowAutoPosterDecode, isFalse);
      expect(VideoCompatMode.preferSoftware.capturePosterFromPlayer, isTrue);
      expect(VideoCompatMode.preferSoftware.maxConcurrentOverride, 1);

      expect(VideoCompatMode.platformViewSoftware.nativeDecoderMode,
          'prefer_software');
      expect(
          VideoCompatMode.platformViewSoftware.allowAutoPosterDecode, isFalse);
      expect(VideoCompatMode.platformViewSoftware.capturePosterFromPlayer,
          isFalse);
      expect(VideoCompatMode.platformViewSoftware.maxConcurrentOverride, 1);
    });
  });

  group('StorageService 持久化', () {
    test('默认标准模式，写入落盘后重启可读回，clearAll 复位为标准模式', () async {
      expect(StorageService.getVideoCompatMode(), VideoCompatMode.standard);

      StorageService.setVideoCompatMode(VideoCompatMode.smartSoftware);
      await StorageService.debugFlushPending();

      StorageService.resetForTests();
      await StorageService.ensureInitialized();
      expect(
          StorageService.getVideoCompatMode(), VideoCompatMode.smartSoftware);

      StorageService.setVideoCompatMode(VideoCompatMode.platformViewSoftware);
      await StorageService.debugFlushPending();

      StorageService.resetForTests();
      await StorageService.ensureInitialized();
      expect(StorageService.getVideoCompatMode(),
          VideoCompatMode.platformViewSoftware);

      await StorageService.clearAll();
      expect(StorageService.getVideoCompatMode(), VideoCompatMode.standard);
    });

    test('外部播放器模式：默认关闭，写入落盘可恢复，clearAll 复位为关闭', () async {
      expect(StorageService.isExternalVideoPlayer(), isFalse);

      StorageService.setExternalVideoPlayer(true);
      expect(StorageService.isExternalVideoPlayer(), isTrue);
      await StorageService.debugFlushPending();

      StorageService.resetForTests();
      await StorageService.ensureInitialized();
      expect(StorageService.isExternalVideoPlayer(), isTrue);

      await StorageService.clearAll();
      expect(StorageService.isExternalVideoPlayer(), isFalse);
    });
  });

  group('VideoDecoderPool 优先软解单路限制', () {
    test('preferSoftware 覆盖并发上限为 1，即使 captureUnavailable 也不放开', () {
      final pool = VideoDecoderPool(
        policy: DecoderPolicy(
          budget: DecodeBudget(initial: 3, ceiling: 3, successStreakToRaise: 999),
        ),
        note: (_, __) {},
        saveBudget: (_) {},
        maxOverride: () =>
            VideoCompatMode.preferSoftware.maxConcurrentOverride,
      );

      expect(pool.max, 1);
      final a = _FakeSlotUser();
      final b = _FakeSlotUser();
      expect(pool.request(a), isTrue);
      expect(pool.request(b), isFalse);
      expect(pool.liveCount, 1);
      expect(pool.waitingCount, 1);

      pool.noteCaptureUnavailable();
      expect(pool.liveCount, 1, reason: '存在显式单路硬上限时不受抓帧不可用解锁影响');
      expect(b.grantedCount, 0);
      // 排队者不该被"撤销"：它从来没拿到过槽位，撤销回调只该发给真正持槽的人。
      expect(b.revokedCount, 0);
    });
  });
}
