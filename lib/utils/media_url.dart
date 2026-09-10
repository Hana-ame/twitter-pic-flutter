// media_url.dart
// pbs.twimg.com 的图片支持用 name= 查询参数取不同尺寸的变体（同一 CDN 后端，
// 也就是 video-cf.twimg.com 同样支持）：
//
//   name=orig / large  → 原始、最大 2048
//   name=medium        → 最大 1200
//   name=small         → 最大 680
//
// 列表/网格里按原始尺寸拉一张图要几百 KB 到 1MB+，上下滑动时来不及出图就是
// 一片空白。列表改用 medium 变体（一个手机屏幕宽度足够），流量和等待都降到
// 几分之一；全屏预览和下载仍然用原图。
//
// 视频（video.twimg.com 的 .mp4、只有 tag= 参数）没有尺寸变体，原样返回。

class MediaUrl {
  MediaUrl._();

  /// 列表缩略图使用的 name 变体。
  static const String gridName = 'medium';

  /// 是否是可以套 name= 变体的图片 URL。
  static bool hasSizeVariant(String url) =>
      url.contains('pbs.twimg.com') && url.contains('name=');

  /// 列表/网格缩略图。
  static String grid(String url) => withName(url, gridName);

  /// 换成指定的 name 变体；不适用（视频、没有 name 参数）时原样返回。
  static String withName(String url, String name) {
    if (!hasSizeVariant(url)) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final query = Map<String, String>.from(uri.queryParameters);
    query['name'] = name;
    return uri.replace(queryParameters: query).toString();
  }
}
