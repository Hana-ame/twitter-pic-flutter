// video_slider_with_buffer.dart
// 带缓冲显示的进度条：一根条上看三种状态，避免出现"两根加载条"。
//   * 白色实心 = 已播放；
//   * 半透明白 = 已缓冲（边下边播的进度）；
//   * 透明 = 还没下到。
//
// 卡片控制栏与全屏页共用（以前各自有一份一模一样的实现）。

import 'package:flutter/material.dart';

class VideoSliderWithBuffer extends StatelessWidget {
  final double value;
  final double max;

  /// 已缓冲比例；null = 信息不足/已缓冲完（不画这条线）。
  final double? buffered;
  final VoidCallback onStart;
  final ValueChanged<double> onEnd;

  const VideoSliderWithBuffer({
    super.key,
    required this.value,
    required this.max,
    required this.buffered,
    required this.onStart,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = (buffered ?? 0).clamp(0.0, 1.0);
    return Stack(
      alignment: Alignment.center,
      children: [
        if (fraction > 0)
          Padding(
            // 对齐 Slider 轨道两端的内缩（滑块半径 + 控件内边距）。
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: fraction,
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: Colors.white38,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: Colors.white,
            // 轨道下半段留空，露出底下的缓冲条。
            inactiveTrackColor: Colors.transparent,
            thumbColor: Colors.white,
            overlayColor: Colors.white24,
          ),
          child: Slider(
            value: value.clamp(0, max <= 0 ? 1 : max),
            max: max <= 0 ? 1 : max,
            onChanged: (_) => onStart(),
            onChangeEnd: onEnd,
          ),
        ),
      ],
    );
  }
}
