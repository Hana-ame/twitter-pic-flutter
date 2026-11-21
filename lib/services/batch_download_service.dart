// batch_download_service.dart
// 媒体批量下载通道：从 UserDetailScreen 拆出，复用共享 MediaHttpClient 连接池，
// 避免每下载一个文件就新建并销毁一次 HttpClient。

import 'dart:io';
import 'dart:typed_data';

import '../utils/ech_url.dart';
import 'media_http_client.dart';

class BatchDownloadService {
  BatchDownloadService._();

  /// 主通道：经本机 ECH 代理流式写入文件。
  static Future<bool> downloadViaProxy({
    required String url,
    required int port,
    required File file,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final echUrl = EchUrl.rewrite(url, port);
    return streamToFile(Uri.parse(echUrl), file, timeout: timeout);
  }

  /// 兼容通道：经本机 ECH 代理整包读入内存后落盘（用于对比排查）。
  static Future<bool> downloadViaProxyLegacy({
    required String url,
    required int port,
    required File file,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final echUrl = EchUrl.rewrite(url, port);
    final client = MediaHttpClient.shared;
    try {
      final req = await client.getUrl(Uri.parse(echUrl)).timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        await res.drain<void>();
        return false;
      }
      final bb = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(timeout)) {
        bb.add(chunk);
      }
      await file.writeAsBytes(bb.takeBytes());
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 应急通道：直连原始 URL 流式下载（仅在代理完全失效时使用）。
  static Future<bool> downloadDirect({
    required String url,
    required File file,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return streamToFile(Uri.parse(url), file, timeout: timeout);
  }

  /// 流式写入文件，成功返回 true。
  ///
  /// 连接或写入任一步失败时关闭句柄并删除半写文件，避免残留损坏文件；
  /// 使用共享 [MediaHttpClient.shared] 复用回环 Keep-Alive 连接。
  static Future<bool> streamToFile(
    Uri uri,
    File file, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final client = MediaHttpClient.shared;
    RandomAccessFile? raf;
    var ok = false;
    try {
      final req = await client.getUrl(uri).timeout(timeout);
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return false;
      }
      final rafHandle = await file.open(mode: FileMode.write);
      raf = rafHandle;
      await for (final chunk in resp.timeout(timeout)) {
        await rafHandle.writeFrom(chunk);
      }
      await rafHandle.close();
      raf = null;
      ok = true;
      return true;
    } catch (_) {
      return false;
    } finally {
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      if (!ok) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }
}
