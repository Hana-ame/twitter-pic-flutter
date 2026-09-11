// media_url.dart
// 媒体 URL 一律用 origin —— 不做 name= 尺寸档位。
//
// 历史：这里曾经按「卡片像素宽度 × 设备像素比」挑 small/medium/large 档，
// 动机是列表按原图拉会白屏（见 README 的实测表与 git 历史）。现在改为全部
// origin，理由是同一张图只对应一个 canonical URL：
//   - 缓存 key 唯一：本机 HTTP 缓存 / 服务端 / CDN 都只有一份，不会同一张图
//     存四份；
//   - 客户端不需要理解 twimg 的档位语义，也就不会再有"三端档位不一致"；
//   - 代价是列表带宽变大，由预取、逐块解码与 HTTP 缓存承担。
//
// 唯一保留下来的判断是"能不能预取"：视频动辄几 MB，预热它们只会把流量打爆，
// 所以预取前先用 [isImage] 过滤。

class MediaUrl {
  MediaUrl._();

  /// 是否是 pbs 图片（可以预取；视频不在预取范围内）。
  ///
  /// 按 **host** 精确判定，不用子串匹配：`contains('pbs.twimg.com')` 会被
  /// `https://evil.com/pbs.twimg.com/stolen.jpg` 和
  /// `https://pbs.twimg.com.evil.com/x.jpg` 骗过，让非 CDN 资源走预取路径
  /// 白白吃流量（这条预取链走的是本机代理，多拉一份就是多一分带宽）。
  ///
  /// 只判定原始 twimg 域名：调用方拿的是后端返回的原始 URL，
  /// 重写成本机代理地址是在调用点之后才发生的。
  static bool isImage(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    // video / video-cf / amplify 都是视频 CDN（视频动辄几 MB，预热会打爆流量）。
    if (uri.host == 'video.twimg.com' ||
        uri.host == 'video-cf.twimg.com' ||
        uri.host == 'abs.twimg.com') return false;
    return uri.host == 'pbs.twimg.com';
  }
}
