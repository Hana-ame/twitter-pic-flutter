// 逐块解码通道的单元测试：不联网，只测节流逻辑与 provider 的缓存标识。

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/widgets/progressive_image.dart';

void main() {
  test('增量太小不解码（避免每个小包都重解整张图）', () {
    final t = ProgressiveDecodeThrottle();
    final now = DateTime(2026, 1, 1);
    expect(t.shouldDecode(8 * 1024, now), isFalse);
    expect(t.shouldDecode(24 * 1024, now), isTrue);
  });

  test('两次解码之间必须有最小间隔', () {
    final t = ProgressiveDecodeThrottle(
      minInterval: const Duration(milliseconds: 120),
    );
    final t0 = DateTime(2026, 1, 1);
    expect(t.shouldDecode(64 * 1024, t0), isTrue);
    t.mark(64 * 1024, t0);

    final soon = t0.add(const Duration(milliseconds: 50));
    expect(t.shouldDecode(200 * 1024, soon), isFalse);

    final later = t0.add(const Duration(milliseconds: 200));
    expect(t.shouldDecode(200 * 1024, later), isTrue);
  });

  test('越往后越稀疏：增量要超过已解码量的 1/4', () {
    final t = ProgressiveDecodeThrottle(
      minDeltaBytes: 1024,
      minInterval: Duration.zero,
    );
    final now = DateTime(2026, 1, 1);
    expect(t.shouldDecode(100 * 1024, now), isTrue);
    t.mark(100 * 1024, now);

    // 只多 20KB < 100KB/4 → 仍然不解码
    expect(t.shouldDecode(120 * 1024, now), isFalse);
    // 多过 25KB → 解码
    expect(t.shouldDecode(131 * 1024, now), isTrue);
  });

  test('相同 URL 的 provider 相等，才能命中 ImageCache', () {
    const url =
        'http://127.0.0.1:8443/media/HRHinAZa8AA7G2D?format=jpg&name=orig';
    final a = ProgressiveImageProvider(url);
    final b = ProgressiveImageProvider(url);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));

    expect(
      ProgressiveImageProvider(url),
      isNot(equals(ProgressiveImageProvider('$url&x=1'))),
    );
  });
}
