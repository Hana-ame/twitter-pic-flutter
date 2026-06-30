// 标签控制页面：管理高亮和屏蔽标签
import 'package:flutter/material.dart';

import '../services/storage_service.dart';
import 'horizontal_button_row.dart';

const _kDefaultBlockTags = [
  '无关内容', '男性', '男娘', '人妖', '露屌', '阳痿', '男同',
];

class TagControllerScreen extends StatefulWidget {
  const TagControllerScreen({super.key});

  @override
  State<TagControllerScreen> createState() => _TagControllerScreenState();
}

class _TagControllerScreenState extends State<TagControllerScreen> {
  final _inputCtrl = TextEditingController();
  List<String> _highlight = [];
  List<String> _block = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final rules = StorageService.getTagRules();
    _highlight = (rules['highlight'] as List?)?.cast<String>() ?? [];
    final storedBlock = (rules['block'] as List?)?.cast<String>() ?? [];
    final hasIntersection = _kDefaultBlockTags.any((t) => _highlight.contains(t));
    if (!hasIntersection) {
      _block = {..._kDefaultBlockTags, ...storedBlock}.toList();
    } else {
      _block = storedBlock.isEmpty ? ['无关内容'] : storedBlock;
    }
    _save();
  }

  void _save() {
    StorageService.setTagRules({
      'highlight': _highlight,
      'block': _block,
    });
  }

  void _addTag(String type) {
    final tag = _inputCtrl.text.trim();
    if (tag.isEmpty) return;
    setState(() {
      if (type == 'highlight') {
        _block.remove(tag);
        if (!_highlight.contains(tag)) _highlight.add(tag);
      } else {
        _highlight.remove(tag);
        if (!_block.contains(tag)) _block.add(tag);
      }
      _inputCtrl.clear();
      _save();
    });
  }

  void _removeTag(String tag, String type) {
    setState(() {
      if (type == 'highlight') _highlight.remove(tag);
      else _block.remove(tag);
      _save();
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('标签显示控制', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(
            controller: _inputCtrl,
            decoration: const InputDecoration(
              hintText: '输入标签名称...',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _addTag('highlight'),
          ),
          const SizedBox(height: 8),
          HorizontalButtonRow(buttons: [
            ElevatedButton.icon(
              onPressed: _inputCtrl.text.trim().isEmpty ? null : () => _addTag('highlight'),
              icon: const Icon(Icons.visibility, size: 16),
              label: const Text('高亮'),
            ),
            ElevatedButton.icon(
              onPressed: _inputCtrl.text.trim().isEmpty ? null : () => _addTag('block'),
              icon: const Icon(Icons.visibility_off, size: 16),
              label: const Text('屏蔽'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade50),
            ),
          ]),
          const SizedBox(height: 16),
          Text('高亮显示 (${_highlight.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6, runSpacing: 4,
            children: _highlight.isEmpty
                ? [const Text('无高亮标签', style: TextStyle(color: Colors.grey))]
                : _highlight.map((t) => Chip(
                    label: Text(t, style: const TextStyle(fontSize: 12)),
                    onDeleted: () => _removeTag(t, 'highlight'),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  )).toList(),
          ),
          const Divider(),
          Text('已屏蔽 (${_block.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6, runSpacing: 4,
            children: _block.isEmpty
                ? [const Text('无屏蔽标签', style: TextStyle(color: Colors.grey))]
                : _block.map((t) => Chip(
                    label: Text(t, style: const TextStyle(fontSize: 12)),
                    onDeleted: () => _removeTag(t, 'block'),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  )).toList(),
          ),
        ],
      ),
    );
  }
}
