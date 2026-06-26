// 简易搜索栏组件
import 'package:flutter/material.dart';

class SearchBarWidget extends StatelessWidget {
  final ValueChanged<String> onChanged;
  final String placeholder;

  const SearchBarWidget({
    super.key,
    required this.onChanged,
    this.placeholder = '搜索...',
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: TextField(
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: placeholder,
          prefixIcon: const Icon(Icons.search, size: 20),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          isDense: true,
        ),
      ),
    );
  }
}
