// 搜索栏组件：支持搜索历史、清除历史
import 'package:flutter/material.dart';

import '../services/storage_service.dart';

class SearchBarWidget extends StatefulWidget {
  final ValueChanged<String> onChanged;
  final String placeholder;

  const SearchBarWidget({
    super.key,
    required this.onChanged,
    this.placeholder = '搜索用户名或昵称...',
  });

  @override
  State<SearchBarWidget> createState() => _SearchBarWidgetState();
}

class _SearchBarWidgetState extends State<SearchBarWidget> {
  List<String> _history = [];
  bool _showHistory = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  void _loadHistory() {
    _history = StorageService.getSearchHistory();
  }

  void _saveToHistory(String query) {
    final q = query.trim();
    if (q.isEmpty) return;

    setState(() {
      // 去重并限制数量
      _history.remove(q);
      _history.insert(0, q);
      if (_history.length > 10) _history = _history.sublist(0, 10);
    });

    StorageService.saveSearchHistory(_history);
  }

  void _onSubmitted(String query) {
    _saveToHistory(query);
    setState(() => _showHistory = false);
    FocusScope.of(context).unfocus();
  }

  void _clearHistory() {
    setState(() {
      _history = [];
      _showHistory = false;
    });
    StorageService.saveSearchHistory([]);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: TextField(
            onChanged: widget.onChanged,
            onSubmitted: _onSubmitted,
            onTap: () => setState(() => _showHistory = _history.isNotEmpty),
            decoration: InputDecoration(
              hintText: widget.placeholder,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _history.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.history),
                      onPressed: () => setState(() => _showHistory = !_showHistory),
                      tooltip: '搜索历史',
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              isDense: true,
            ),
          ),
        ),
        if (_showHistory && _history.isNotEmpty)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('搜索历史', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
                    TextButton(
                      onPressed: _clearHistory,
                      child: const Text('清除', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: _history.map((h) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.history, size: 16),
                      title: Text(h, style: const TextStyle(fontSize: 13)),
                      onTap: () {
                        widget.onChanged(h);
                        setState(() => _showHistory = false);
                        FocusScope.of(context).unfocus();
                      },
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 14),
                        onPressed: () => setState(() => _history.remove(h)),
                      ),
                    )).toList(),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
