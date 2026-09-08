import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/stable_hash.dart';

void main() {
  group('stableHash（视频缓存文件名的 key）', () {
    test('输出固定 16 位小写十六进制', () {
      final h = stableHash('https://video-cf.twimg.com/video/abc/720p.mp4');
      expect(h.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(h), isTrue, reason: h);
    });

    test('确定性：同一输入任意次结果一致（跨重启缓存有效的前提）', () {
      final url = 'https://x.com/some/user/status/1/video/1';
      expect(stableHash(url), stableHash(url));
      expect(stableHash(url), stableHash(url));
    });

    test('已知向量：防止算法被无意改动导致旧缓存全部失效', () {
      // 由独立实现（Python）按 FNV-1a 64 预计算。
      expect(stableHash('hello'), 'a430d84680aabd0b');
      expect(
        stableHash('https://video-cf.twimg.com/video/FzX3q9abcde/1280x720.mp4'),
        'f32c8d96dd3aa2db',
      );
    });

    test('雪崩性：单字符差异产生完全不同的哈希', () {
      expect(stableHash('url-1'), isNot(stableHash('url-2')));
    });

    test('1000 个 URL 无冲突', () {
      final seen = <String>{};
      for (var i = 0; i < 1000; i++) {
        final h = stableHash('https://pbs.twimg.com/media/$i.jpg');
        if (!seen.add(h)) fail('collision at $i');
      }
      expect(seen.length, 1000);
    });
  });
}
