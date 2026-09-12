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

import '../utils/stable_hash.dart';

class VideoDownloader {
  VideoDownloader._();

  /// 落到系统临时目录并返回文件。**同名碰撞**：不同用户/路径的末段可能都叫
  /// `1.mp4`，拼 `stableHash(url)` 保证唯一（同 downloadToTempFile 的修法）。
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

      final base = url.split('/').last.split('?').first;
      final fileName = '${base}-${stableHash(url)}';
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
}
