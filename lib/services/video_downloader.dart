// video_downloader.dart
// 「下载视频到临时文件」的**唯一**实现。
//
// 以前卡片（twitter_video.dart）和全屏页各有一份逐字复制的 ~40 行下载代码，
// 改一处忘一处（全屏版先加的防重入守卫，卡片版隔了一个版本才补上）。
// 只留一个：UI 各管各的 snackbar / 忙碌态，文件落地逻辑在这里。
//
// 前提：uri 必须已经是经 ECH 代理重写的（调用方负责判 `proxy.port == null`，
// 墙内直连 twimg 必死，不能静默退回原始 URL —— 见 utils/video_failure.dart）。

import 'dart:io';

import '../utils/download_name.dart';

class VideoDownloader {
  VideoDownloader._();

  /// 落到系统临时目录并返回文件。**同名碰撞**：不同用户/路径的末段可能都叫
  /// `1.mp4`，拼 `stableHash(url)` 保证唯一（同 downloadToTempFile 的修法）。
  /// 文件名交给 [videoTempFileName]：哈希在扩展名之前，保证 `.mp4` 是末段
  /// （哈希放后面会把扩展名变成 `.mp4-<hash>`，手机上得手动删多余后缀）。
  static Future<File> fetchToTemp({
    required Uri uri,
    required String url,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final fileName = videoTempFileName(url);
      final file = File('${Directory.systemTemp.path}/$fileName');
      RandomAccessFile? raf;
      try {
        final handle = await file.open(mode: FileMode.write);
        raf = handle;
        await for (final chunk in response) {
          await handle.writeFrom(chunk);
        }
        await handle.close();
        raf = null;
      } catch (_) {
        // 写入失败（磁盘满/连接中断）：关句柄并删掉半截文件，别留损坏的产物。
        if (raf != null) {
          try {
            await raf.close();
          } catch (_) {}
        }
        try {
          await file.delete();
        } catch (_) {}
        rethrow;
      }
      return file;
    } finally {
      client.close();
    }
  }

  /// 匹配分享/下载落盘到系统临时目录的图片或视频临时文件名：
  /// - 图片：`twitter_<16位hex>_*`（见 [imageTempFileName]）
  /// - 视频：`*-<16位hex>.(mp4|mov|webm|m4v)`（见 [videoTempFileName]）
  static final RegExp _kTempShareFilePattern = RegExp(
    r'^(?:twitter_[0-9a-f]{16}_.+|.+-[0-9a-f]{16}\.(?:mp4|mov|webm|m4v))$',
    caseSensitive: false,
  );

  /// 清理系统临时目录下超过 [maxAge] 的历史分享/下载临时文件（默认 24 小时）。
  /// 在应用启动与设置页「清除数据」（传 `Duration.zero`）时调用，防止临时视频撑爆存储。
  static Future<int> cleanExpiredTempFiles({
    Duration maxAge = const Duration(hours: 24),
    Directory? tempDir,
  }) async {
    final dir = tempDir ?? Directory.systemTemp;
    var deleted = 0;
    try {
      if (!await dir.exists()) return 0;
      final now = DateTime.now();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isNotEmpty
            ? entity.uri.pathSegments.last
            : entity.path.split(Platform.pathSeparator).last;
        if (!_kTempShareFilePattern.hasMatch(name)) continue;
        try {
          if (maxAge > Duration.zero) {
            final stat = await entity.stat();
            if (now.difference(stat.modified) < maxAge) continue;
          }
          await entity.delete();
          deleted++;
        } catch (_) {}
      }
    } catch (_) {}
    return deleted;
  }
}
