// 标签展示区域，渲染用户标签及其评分颜色
import 'package:flutter/material.dart';

class TagDisplayArea extends StatelessWidget {
  final Map<String, dynamic> tags;

  const TagDisplayArea({super.key, required this.tags});

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 6, runSpacing: 4,
        children: tags.entries.map((e) {
          final score = (e.value as num).toInt();
          final color = score > 0 ? Colors.blue : Colors.red;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            child: Text(e.key, style: TextStyle(fontSize: 11, color: Color.lerp(color, Colors.black, 0.3)!)),
          );
        }).toList(),
      ),
    );
  }
}
