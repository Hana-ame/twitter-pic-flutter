// 媒体 URL 一律 origin：这里只保留"能不能预取"的判定（图片 vs 视频）。
// 用例里的 URL 形态取自线上真实数据（图片带 name=orig，视频只有 tag= 或没有参数）。
//
// 注意：现在没有任何地方再改写 name= 档位，所以"URL 原样透传（含 query）"这条
// 由 ech_url_test.dart 与后端 scanner 的测试保证。

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/media_url.dart';

void main() {
  test('pbs 图片可以预取', () {
    const urls = [
      'https://pbs.twimg.com/media/HRHinAZa8AA7G2D?format=jpg&name=orig',
      'https://pbs.twimg.com/media/X?format=png',
      'https://pbs.twimg.com/media/X',
    ];
    for (final u in urls) {
      expect(MediaUrl.isImage(u), isTrue, reason: u);
    }
  });

  test('视频不预取（动辄几 MB）', () {
    const urls = [
      'https://video.twimg.com/amplify_video/2097617825540259841/vid/avc1/720x720/75c94t9V9JHmLuJp.mp4?tag=29',
      // 线上真实存在的一类：连查询参数都没有。
      'https://video.twimg.com/amplify_video/2066068672284925952/vid/avc1/720x1280/XswFVltK9wrkjJbI.mp4',
    ];
    for (final u in urls) {
      expect(MediaUrl.isImage(u), isFalse, reason: u);
    }
  });

  test('非 pbs / 空 / 非法 URL 不预取也不抛异常', () {
    expect(MediaUrl.isImage('https://example.com/a.jpg?name=orig'), isFalse);
    expect(MediaUrl.isImage('not a url'), isFalse);
    expect(MediaUrl.isImage(''), isFalse);
  });

  test('按 host 判定，不被包含 pbs.twimg.com 字样的 URL 骗过', () {
    // 原来是 contains('pbs.twimg.com') 子串匹配，下面这几条都会被误判成图片
    // 从而进入预取链路 —— 预取走的是本机代理，多拉一份就是多一分带宽。
    expect(MediaUrl.isImage('https://evil.com/pbs.twimg.com/stolen.jpg'),
        isFalse);
    expect(MediaUrl.isImage('https://pbs.twimg.com.evil.com/x.jpg'), isFalse);
    expect(MediaUrl.isImage('https://pbs.twimg.com.evil.com/video-cf/x.mp4'),
        isFalse);
    // 没有 scheme 的裸串不是合法 URL，也不能放行
    expect(MediaUrl.isImage('pbs.twimg.com/media/x.jpg'), isFalse);
    // 视频 CDN 的另一个域名同样不预取
    expect(MediaUrl.isImage('https://video-cf.twimg.com/media/x.mp4'), isFalse);
  });
}
