// frame_luma_test.dart
// 封面抓帧的黑帧判定。
//
// **发现背景**：`RepaintBoundary.toImage` 在部分平台/时序下抓不到 `Texture`，
// 得到整片黑 —— 黑封面比没有封面更糟（用户以为视频本身是黑的），所以抓完先
// 验一遍（原实现内联在 1700 行的 twitter_video.dart 里没法测，v0.5.13 拆到
// utils/frame_luma.dart 后才有这个测试）。锁两个点：全黑/全亮判对、
// 抽样步长必须能扫到所有行（质数步长的初衷）。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/frame_luma.dart';

Uint8List _rgba(int w, int h, int Function(int x, int y) luma) {
  final b = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = luma(x, y);
      final i = (y * w + x) * 4;
      b[i] = v;
      b[i + 1] = v;
      b[i + 2] = v;
      b[i + 3] = 255;
    }
  }
  return b;
}

void main() {
  test('全黑 → 判黑；全亮 → 不判黑', () {
    expect(isMostlyBlack(_rgba(64, 64, (_, __) => 0)), isTrue);
    expect(isMostlyBlack(_rgba(64, 64, (_, __) => 200)), isFalse);
  });

  test('空缓冲（抓帧异常返回 0 字节）按黑处理', () {
    expect(isMostlyBlack(Uint8List(0)), isTrue);
  });

  test('亮像素 <2% 判黑，>2% 放行', () {
    // 200x100 = 2 万像素；只点亮 200 个 = 恰好 1% → 黑。
    final few = _rgba(200, 100, (x, y) => (x == 0 && y == 0) ? 200 : 0);
    expect(isMostlyBlack(few), isTrue);
    // 每隔 10 个点一个 = 20% → 放行。
    final many = _rgba(200, 100, (x, y) => (x % 10 == 0 && y % 2 == 0) ? 200 : 0);
    expect(isMostlyBlack(many), isFalse);
  });

  test('质数步长不会共振漏检：亮像素只在特定行/列交错时仍能被扫到', () {
    // 构造"每隔 4 个像素亮一个"的图案：若步长是 2 的幂/与行宽有公因子，
    // 采样可能永远踩不亮；53（质数，且 4*53 与任意常见行宽互质）保证扫到。
    final stripes = _rgba(211, 157, (x, y) => ((y * 211 + x) % 4 == 0) ? 120 : 0);
    expect(isMostlyBlack(stripes), isFalse);
  });
}
