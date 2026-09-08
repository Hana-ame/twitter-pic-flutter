// 标签展示区域，渲染用户标签及其评分颜色
import 'package:flutter/material.dart';

import '../services/storage_service.dart';

class TagDisplayArea extends StatelessWidget {
  final Map<String, dynamic> tags;

  /// 高亮集合；null 时从 StorageService 读取。
  /// 可注入以便测试（避免依赖本地存储）。
  final Set<String>? highlights;

  const TagDisplayArea({super.key, required this.tags, this.highlights});

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    // 命中“标签管理→高亮”的 tag 加星标强调（规则原先存了但从不生效）。
    final hits = highlights ?? StorageService.getHighlightTags().toSet();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 6, runSpacing: 4,
        children: tags.entries.map((e) {
          final score = (e.value as num).toInt();
          final color = score > 0 ? Colors.blue : Colors.red;
          final isHighlighted = hits.contains(e.key);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: isHighlighted ? 0.18 : 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isHighlighted ? Colors.amber.shade400 : color.withValues(alpha: 0.2),
                width: isHighlighted ? 1.4 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isHighlighted) ...[
                  Icon(Icons.star, size: 11, color: Colors.amber.shade700),
                  const SizedBox(width: 3),
                ],
                Text(e.key,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: isHighlighted ? FontWeight.w600 : null,
                      color: Color.lerp(color, Colors.black, 0.3)!,
                    )),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
