// pbs 图片的 name= 尺寸变体改写：列表按显示尺寸挑档位，全屏/下载用原图。
// 用例里的 URL 形态取自线上真实数据（name=orig）。

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/media_url.dart';

void main() {
  test('pbs 图片换成列表缩略图变体（保留 format 等其它参数）', () {
    expect(
      MediaUrl.grid(
          'https://pbs.twimg.com/media/HRHinAZa8AA7G2D?format=jpg&name=orig'),
      'https://pbs.twimg.com/media/HRHinAZa8AA7G2D?format=jpg&name=medium',
    );
    expect(
      MediaUrl.grid('https://pbs.twimg.com/media/X?format=png&name=large'),
      'https://pbs.twimg.com/media/X?format=png&name=medium',
    );
  });

  test('视频没有尺寸变体，原样返回', () {
    const video =
        'https://video.twimg.com/ext_tw_video/1/pu/vid/1016x720/x.mp4?tag=10';
    expect(MediaUrl.grid(video), video);
    expect(MediaUrl.hasSizeVariant(video), isFalse);
  });

  test('没带 name= 的 pbs 图也补上缩略图变体（线上数据形态不一）', () {
    expect(
      MediaUrl.grid('https://pbs.twimg.com/media/X?format=jpg'),
      'https://pbs.twimg.com/media/X?format=jpg&name=medium',
    );
    expect(MediaUrl.grid('https://pbs.twimg.com/media/X'),
        'https://pbs.twimg.com/media/X?name=medium');
  });

  test('视频 / 非 pbs / 非法 URL 时不改动也不抛异常', () {
    const other = 'https://example.com/a.jpg?name=orig';
    expect(MediaUrl.grid(other), other);
    expect(MediaUrl.grid('not a url'), 'not a url');
    expect(MediaUrl.grid(''), '');
  });

  test('按所需像素挑最小够用的档位', () {
    const url = 'https://pbs.twimg.com/media/X?format=jpg&name=orig';
    expect(MediaUrl.gridFor(url, neededPixels: 600),
        'https://pbs.twimg.com/media/X?format=jpg&name=small');
    expect(MediaUrl.gridFor(url, neededPixels: 680),
        'https://pbs.twimg.com/media/X?format=jpg&name=small');
    expect(MediaUrl.gridFor(url, neededPixels: 1080),
        'https://pbs.twimg.com/media/X?format=jpg&name=medium');
    expect(MediaUrl.gridFor(url, neededPixels: 1200),
        'https://pbs.twimg.com/media/X?format=jpg&name=medium');
    expect(MediaUrl.gridFor(url, neededPixels: 1600),
        'https://pbs.twimg.com/media/X?format=jpg&name=large');
  });

  test('线上真实视频 URL（含无查询参数的那种）一律不动', () {
    const withTag =
        'https://video.twimg.com/amplify_video/2097617825540259841/vid/avc1/720x720/75c94t9V9JHmLuJp.mp4?tag=29';
    const noQuery =
        'https://video.twimg.com/amplify_video/2066068672284925952/vid/avc1/720x1280/XswFVltK9wrkjJbI.mp4';
    for (final u in [withTag, noQuery]) {
      expect(MediaUrl.gridFor(u, neededPixels: 1080), u);
      expect(MediaUrl.grid(u), u);
    }
  });

  test('可指定任意变体', () {
    expect(
      MediaUrl.withName(
          'https://pbs.twimg.com/media/X?format=jpg&name=small', 'large'),
      'https://pbs.twimg.com/media/X?format=jpg&name=large',
    );
  });
}
