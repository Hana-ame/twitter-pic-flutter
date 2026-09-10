// media_url.dart
// 图片尺寸变体：列表别拉原图。
//
// 线上真实数据（x.moonchan.xyz/api/twitter/<user>.json.gz 抽查 6 个用户、
// 2209 条）只有两种形态：
//   photo 1704 条：https://pbs.twimg.com/media/<id>?format=jpg&name=orig
//   video  505 条：https://video.twimg.com/.../<name>.mp4?tag=29
//                  （其中 238 条连查询参数都没有）
//
// 也就是图片全是 name=orig —— 最重的一档，一张动辄几 MB。列表按它拉，上下
// 滑动时来不及出图就是一片空白。
//
// twimg 的 name 档位：small(≤680) / medium(≤1200) / large(≤2048) / orig。
// 你们后端 gallery/scanner.go 的 thumbVariant() 用的是 name=small（网格小图
// 够用）。这里按显示尺寸挑最小够用的那一档：卡片有多宽、屏幕几倍密度，就取
// 能盖住的那档，既不模糊也不白拉流量。视频一律不碰（没有尺寸变体）。

import 'package:flutter/widgets.dart';

class MediaUrl {
  MediaUrl._();

  static const String smallName = 'small';
  static const String mediumName = 'medium';
  static const String largeName = 'large';

  /// 判断不出显示尺寸时用的兜底档位。
  static const String gridName = mediumName;

  /// 是否是可以套 name= 变体的图片 URL。
  ///
  /// 只看域名：线上图片是 pbs.twimg.com（现在都带 name=orig），视频是
  /// video.twimg.com（只有 tag=，甚至没有查询参数），必须放过。
  static bool hasSizeVariant(String url) =>
      url.contains('pbs.twimg.com') && !url.contains('video.twimg.com');

  /// 列表缩略图：按所需像素挑最小够用的档位。
  ///
  /// [neededPixels] 是这张图实际要显示的像素宽度（逻辑宽度 × 设备像素比）。
  static String gridFor(String url, {required int neededPixels}) {
    if (!hasSizeVariant(url)) return url;
    if (neededPixels <= 680) return withName(url, smallName);
    if (neededPixels <= 1200) return withName(url, mediumName);
    return withName(url, largeName);
  }

  /// 默认档位的缩略图（判断不出显示尺寸时用）。
  static String grid(String url) => withName(url, gridName);

  /// 卡片实际要显示的像素宽度：详情页左右各 12 内边距 + 卡片 8 外边距。
  ///
  /// 用 MediaQuery 取屏幕逻辑宽度与设备像素比，避免拍脑袋定死档位。
  static int gridPixelsFor(BuildContext context) {
    final logical = MediaQuery.sizeOf(context).width - 40;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final px = (logical * dpr).round();
    return px < 1 ? 1 : px;
  }

  /// 换成指定的 name 变体（没有 name 参数就补上）；视频等不适用时原样返回。
  static String withName(String url, String name) {
    if (!hasSizeVariant(url)) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    // 保留 format 等其它参数与原顺序，只改 name。
    final query = Map<String, String>.from(uri.queryParameters);
    query['name'] = name;
    return uri.replace(queryParameters: query).toString();
  }
}
