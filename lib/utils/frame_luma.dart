// frame_luma.dart
// 抓帧结果的**黑帧判定**（纯函数，可单测）。
//
// 为什么需要：封面用 `RepaintBoundary.toImage` 抓屏，而 `Texture` 能不能被抓进
// 离屏图像跟平台/时序有关，抓不到会是**整片黑**。黑封面比「点按加载」占位更糟
// （用户会以为视频本身是黑的），所以抓完先验一遍，黑就重试/放弃（见
// widgets/twitter_video.dart 的 _capturePoster）。

import 'dart:typed_data';

/// 抽样判断整帧是否接近全黑（亮像素占比 < 2%）。
///
/// 步长用**质数** 53：2 的幂或常见行宽因子会和采样共振，永远只采到同一列/同一行。
/// 输入必须是 RGBA（每像素 4 字节、行主序），即 `ImageByteFormat.rawRgba`。
bool isMostlyBlack(Uint8List bytes) {
  const step = 53;
  var sampled = 0;
  var lit = 0;
  for (var i = 0; i + 3 < bytes.length; i += 4 * step) {
    sampled++;
    // Rec.601 luma；阈值 12 给黑边/噪点留余量。
    final luma =
        (bytes[i] * 299 + bytes[i + 1] * 587 + bytes[i + 2] * 114) ~/ 1000;
    if (luma > 12) lit++;
  }
  return sampled == 0 || lit * 50 < sampled;
}
