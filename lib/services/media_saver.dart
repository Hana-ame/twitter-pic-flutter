// media_saver.dart
// 单张图片 / 单个视频直接「保存到本地公共 Download 目录」的统一服务。
//
// 为什么需要它：
// 原有图片卡片、全屏相册、视频卡片、全屏播放页只提供「下载并分享」（先写进
// Directory.systemTemp 再弹系统 Share 面板）。在桌面端（Windows）或只想把
// 当前单张图/单个视频存进本地 Download 目录时，每次都弹分享面板非常繁琐。
//
// 核心约束（与架构铁律一致）：
//   1. 媒体必须走本机 ECH 代理（调用方传入经 EchUrl.rewrite 的 proxiedUri）；
//   2. 保存目录使用用户可见的公共 Download 目录（Android `/storage/emulated/0/Download`，
//      Windows `%USERPROFILE%\Downloads`），绝不写进用户看不见的私有目录；
//   3. 文件名拼接 `stableHash(originalUrl)` 防止不同路径下的同名文件（如 `1.jpg`）互相覆盖；
//   4. 写入中途发生异常（断网/磁盘满）时关闭句柄并清理半截文件，绝不残留损坏产物。

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../utils/stable_hash.dart';

/// 保存到本地 Download 目录时因缺少存储权限而失败的异常。
class MediaSavePermissionException implements Exception {
  final String directoryPath;
  final String message;

  const MediaSavePermissionException({
    required this.directoryPath,
    required this.message,
  });

  @override
  String toString() => '缺少文件访问权限（目标目录：$directoryPath）';
}

class MediaSaver {
  MediaSaver._();

  static const Duration _kConnectTimeout = Duration(seconds: 30);
  static const Duration _kOverallTimeout = Duration(seconds: 90);

  /// 获取用户可见的公共 Download 根目录。
  static Future<String> downloadBaseDir() async {
    if (Platform.isAndroid) return '/storage/emulated/0/Download';
    if (Platform.isWindows) {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '.';
      return '$home\\Downloads';
    }
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  /// 根据原始媒体 URL 生成防碰撞的安全文件名。
  ///
  /// 格式：`[username_]<safeBase>_<hash8>.<ext>`
  static String buildFileName(
    String originalUrl, {
    String? username,
    bool isVideo = false,
  }) {
    final ext = isVideo ? '.mp4' : _inferImageExt(originalUrl);
    final rawLast = originalUrl.split('/').last.split('?').first;
    final dotIdx = rawLast.lastIndexOf('.');
    final rawStem = dotIdx > 0 ? rawLast.substring(0, dotIdx) : rawLast;
    final safeStem = rawStem
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final stem = safeStem.isEmpty ? (isVideo ? 'video' : 'image') : safeStem;
    final hash8 = stableHash(originalUrl).substring(0, 8);
    final cleanUser = (username ?? '')
        .trim()
        .replaceFirst(RegExp(r'^@+'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    final prefix = cleanUser.isEmpty ? 'twitter' : cleanUser;
    return '${prefix}_${stem}_$hash8$ext';
  }

  static String _inferImageExt(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('format=png') || lower.split('?').first.endsWith('.png')) {
      return '.png';
    }
    if (lower.contains('format=webp') ||
        lower.split('?').first.endsWith('.webp')) {
      return '.webp';
    }
    if (lower.contains('format=gif') || lower.split('?').first.endsWith('.gif')) {
      return '.gif';
    }
    return '.jpg';
  }

  /// 经本机代理 URL [proxiedUri] 流式下载媒体并保存到本地公共 Download 目录。
  ///
  /// [subFolder] 默认为 `'TwitterPic'`（若指定用户名可传用户名）。
  /// [baseDirOverride] 仅供单元测试注入临时目录。
  static Future<File> saveToDownloads({
    required Uri proxiedUri,
    required String originalUrl,
    String? username,
    String? subFolder,
    bool isVideo = false,
    Directory? baseDirOverride,
  }) async {
    final basePath =
        baseDirOverride != null ? baseDirOverride.path : await downloadBaseDir();
    final folder = (subFolder != null && subFolder.trim().isNotEmpty)
        ? subFolder.trim()
        : ((username != null && username.trim().isNotEmpty)
            ? username.trim().replaceFirst(RegExp(r'^@+'), '')
            : 'TwitterPic');
    final targetDir = Directory('$basePath${Platform.pathSeparator}$folder');
    try {
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
    } on FileSystemException catch (e) {
      final msg = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
      if (msg.contains('permission') || msg.contains('eacces')) {
        throw MediaSavePermissionException(
          directoryPath: targetDir.path,
          message: e.toString(),
        );
      }
      rethrow;
    }

    final fileName = buildFileName(
      originalUrl,
      username: username,
      isVideo: isVideo,
    );
    final file = File('${targetDir.path}${Platform.pathSeparator}$fileName');

    final client = HttpClient()..connectionTimeout = _kConnectTimeout;
    final deadline = Timer(_kOverallTimeout, () {
      client.close(force: true);
    });
    RandomAccessFile? raf;
    var ok = false;
    try {
      final req = await client.getUrl(proxiedUri);
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}', uri: proxiedUri);
      }
      final handle = await file.open(mode: FileMode.write);
      raf = handle;
      var written = 0;
      await for (final chunk in resp) {
        await handle.writeFrom(chunk);
        written += chunk.length;
      }
      await handle.close();
      raf = null;
      if (written == 0) {
        throw const FileSystemException('下载响应为空（0 字节）');
      }
      ok = true;
      return file;
    } finally {
      deadline.cancel();
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      client.close(force: true);
      if (!ok) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }
}
