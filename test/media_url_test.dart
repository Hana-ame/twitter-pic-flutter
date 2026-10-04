// 媒体 URL：列表用 name=small 缩略图，详情/预览用原图 origin。
// 用例里的 URL 形态取自线上真实数据（图片带 name=orig，视频只有 tag= 或没有参数）。
//
// v0.6.1 起 [MediaUrl.thumbOf] 会改写 name= 档位，所以"原样透传"这条不再成立——
// 改由下面两组用例保证：**只动 name=、其余参数与 path 一个字节都不变**。

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/media_url.dart';

/// 取出 query 里的某个参数值（测试自己解析，顺带验证 URL 结构没被破坏）。
String? paramOf(String url, String key) {
  final idx = url.indexOf('?');
  if (idx < 0) return null;
  for (final pair in url.substring(idx + 1).split('&')) {
    final kv = pair.split('=');
    if (kv.first == key) return kv.length > 1 ? kv[1] : '';
  }
  return null;
}

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

  // ─── v0.6.1：缩略图档位 ──────────────────────────────────────────────────

  group('thumbOf 只动 name=，其余原样保留', () {
    test('线上真实形态：format 与 name 都换成正确值', () {
      const src = 'https://pbs.twimg.com/media/HRHinAZa8AA7G2D?format=jpg&name=orig';
      final out = MediaUrl.thumbOf(src);
      expect(paramOf(out, 'name'), 'small');
      // format 必须还在：丢了对 CDN 就是 403（"所有图都加载失败"）。
      expect(paramOf(out, 'format'), 'jpg');
    });

    test('path 一个字节都不动', () {
      const src = 'https://pbs.twimg.com/media/HRHinAZa8AA7G2D?format=jpg&name=orig';
      final out = MediaUrl.thumbOf(src);
      expect(out.startsWith('https://pbs.twimg.com/media/HRHinAZa8AA7G2D?'), isTrue,
          reason: 'path 或 host 被动了：$out');
    });

    test('没有 name= 的图片补上档位，但不破坏已有参数', () {
      const src = 'https://pbs.twimg.com/media/X?format=png';
      final out = MediaUrl.thumbOf(src);
      expect(paramOf(out, 'name'), 'small');
      expect(paramOf(out, 'format'), 'png');
    });

    test('完全不带 query 的图片：加档位', () {
      const src = 'https://pbs.twimg.com/media/X';
      final out = MediaUrl.thumbOf(src);
      expect(paramOf(out, 'name'), 'small');
      expect(out.startsWith('https://pbs.twimg.com/media/X?'), isTrue);
    });

    test('signed token 等其余参数全部保留', () {
      const src = 'https://pbs.twimg.com/media/X?name=orig&token=abc123';
      final out = MediaUrl.thumbOf(src);
      expect(paramOf(out, 'name'), 'small');
      expect(paramOf(out, 'token'), 'abc123');
    });
  });

  group('thumbOf 对非图片与畸形 URL 的处理', () {
    test('视频 URL 原样返回（不该去改 mp4 的 name=）', () {
      const src =
          'https://video.twimg.com/amplify_video/1/vid/avc1/720x720/x.mp4?tag=29';
      expect(MediaUrl.thumbOf(src), src);
    });

    test('非 twimg 域名原样返回', () {
      const src = 'https://example.com/a.jpg?name=orig';
      expect(MediaUrl.thumbOf(src), src);
    });

    test('重复 query 键（可能是签名）时宁可原样返回，不弄出坏签名', () {
      // Uri.queryParameters 会把重复键压成一个，token 的前一个副本丢了
      // 就是 403。这里必须选择「不改」而不是「改坏」。
      const src = 'https://pbs.twimg.com/media/X?token=a&token=b&name=orig';
      expect(MediaUrl.thumbOf(src), src);
    });

    test('空串与非法 URL 不抛异常', () {
      expect(MediaUrl.thumbOf(''), '');
      expect(MediaUrl.thumbOf('not a url'), 'not a url');
    });
  });

  group('kOriginName 与档位常量', () {
    test('kListThumbName 是 small（列表甜点档）', () {
      expect(MediaUrl.kListThumbName, 'small');
    });

    test('kOriginName 是 orig（保持既有原图口径）', () {
      expect(MediaUrl.kOriginName, 'orig');
    });
  });
}
