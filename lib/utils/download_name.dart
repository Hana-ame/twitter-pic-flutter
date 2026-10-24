// download_name.dart
// 下载落地文件名拼装（纯函数，便于单测）。
//
// 为修手机上两个手动劳动而建：
//   * 图片临时文件没后缀（`twitter_<hash>_FooBar`）→ 相册/文件管理器不认成
//     图片，用户得手动补 `.jpg`；
//   * 视频临时文件把哈希拼在扩展名**后面**（`xyz.mp4-<hash>`）→ 扩展名变成
//     `.mp4-<hash>`，系统不认成视频，用户得手动删掉多余后缀。
// 统一约定：哈希一律放在扩展名**之前**，文件永远带正确后缀。

import 'media_url.dart';
import 'stable_hash.dart';

/// 图片下载临时文件名（不含路径）。
///
/// 格式 `twitter_<hash>_<safeBase>[.<ext>]`。扩展名取法依次为：
/// 1. [safeBase] 自身末段已带已知扩展名（如 `photo1.jpg`）——直接采用，
///    不重复追加；
/// 2. 响应头 [contentType]（服务端实际返回，最接近真实字节）；
/// 3. URL 推导（[MediaUrl.extFromUrl]，twimg 的 `format=` 参数）；
/// 4. 兜底 jpg（twimg 图片绝大多数是 JPEG）。
String imageTempFileName(String originalUrl, {String? contentType}) {
  final raw = originalUrl.split('/').last.split('?').first;
  final safeBase = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final base = safeBase.isEmpty ? 'file' : safeBase;
  if (_knownExtIn(base) != null) {
    return 'twitter_${stableHash(originalUrl)}_$base';
  }
  final ext = MediaUrl.extFromContentType(contentType) ??
      MediaUrl.extFromUrl(originalUrl) ??
      'jpg';
  return 'twitter_${stableHash(originalUrl)}_$base.$ext';
}

/// 视频下载临时文件名（不含路径）。
///
/// 格式 `<stem>-<hash>.<ext>`：哈希在扩展名**之前**，保证扩展名是最后一段。
/// 路径末段推不出已知扩展名时兜底 mp4（twimg 视频都是 mp4）。
String videoTempFileName(String url) {
  final raw = url.split('/').last.split('?').first;
  final dot = raw.lastIndexOf('.');
  final hasExt = dot > 0 && dot < raw.length - 1;
  final ext = hasExt && MediaUrl.isKnownMediaExt(raw.substring(dot + 1))
      ? raw.substring(dot + 1).toLowerCase()
      : 'mp4';
  var stem = hasExt ? raw.substring(0, dot) : raw;
  stem = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (stem.isEmpty) stem = 'video';
  return '$stem-${stableHash(url)}.$ext';
}

/// [base] 末段扩展名是已知媒体类型时返回它（不带点），否则 null。
String? _knownExtIn(String base) {
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return null;
  final ext = base.substring(dot + 1).toLowerCase();
  return MediaUrl.isKnownMediaExt(ext) ? ext : null;
}
