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
  /// 只看域名：线上图片是 pbs.twimg.com，视频是 video.twimg.com
  /// （视频只有 tag=，甚至没有查询参数，形态与图片不同）。
  static bool isImage(String url) =>
      url.contains('pbs.twimg.com') && !url.contains('video.twimg.com');
}
