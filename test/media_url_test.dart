// pbs 图片的 name= 尺寸变体改写：列表用缩略图，全屏/下载用原图。

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

  test('没有 name 参数 / 非 pbs / 非法 URL 时不改动也不抛异常', () {
    const bare = 'https://pbs.twimg.com/media/X';
    expect(MediaUrl.grid(bare), bare);
    expect(MediaUrl.grid('not a url'), 'not a url');
    expect(MediaUrl.grid(''), '');
  });

  test('可指定任意变体', () {
    expect(
      MediaUrl.withName(
          'https://pbs.twimg.com/media/X?format=jpg&name=small', 'large'),
      'https://pbs.twimg.com/media/X?format=jpg&name=large',
    );
  });
}
