// 标签控制页面：管理高亮和屏蔽标签
import 'package:flutter/material.dart';

import '../services/storage_service.dart';

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
    _inputCtrl.addListener(_onInputChanged);
    _load();
  }

  // 原实现按钮的禁用条件只在 build 时求值、输入不触发重建，
  // 导致打字后"高亮/屏蔽"按钮永远是灰的（只能按回车提交）。
  void _onInputChanged() {
    if (mounted) setState(() {});
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
    _inputCtrl.removeListener(_onInputChanged);
    _inputCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext  context) {
    final hasInput = _inputCtrl.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('标签管理')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _inputCtrl,
              decoration: InputDecoration(
                hintText: '输入标签名称...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                prefixIcon: const Icon(Icons.label_outline, size: 20),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
              onSubmitted: (_) => _addTag('highlight'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: hasInput ? () => _addTag('highlight') : null,
                    icon: const Icon(Icons.visibility, size: 16),
                    label: const Text('高亮'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade50,
                      foregroundColor: Colors.green.shade800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: hasInput ? () => _addTag('block') : null,
                    icon: const Icon(Icons.visibility_off, size: 16),
                    label: const Text('屏蔽'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade50,
                      foregroundColor: Colors.red.shade700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '添加后，详情页中命中的标签会特殊显示；'
              '用户标签命中"屏蔽"时页面顶部会给出提示。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 20),
            _buildSectionHeader(
              Icons.visibility, Colors.green, '高亮显示', _highlight.length),
            const SizedBox(height: 8),
            _buildTagList(_highlight, Colors.green, 'highlight'),
            const SizedBox(height: 20),
            _buildSectionHeader(
              Icons.visibility_off, Colors.red, '已屏蔽', _block.length),
            const SizedBox(height: 8),
            _buildTagList(_block, Colors.red, 'block'),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
      IconData  icon, Color  color, String  title, int  count) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('$count', style: TextStyle(fontSize: 11, color: color)),
        ),
      ],
    );
  }

  Widget _buildTagList(List<String>  tags, Color  color, String  type) {
    if (tags.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          type == 'highlight' ? '无高亮标签' : '无屏蔽标签',
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }
    return Wrap(
      spacing: 6, runSpacing: 6,
      children: tags.map((t) => ActionChip(
        label: Text(t, style: const TextStyle(fontSize: 12)),
        avatar: Icon(Icons.close, size: 14, color: color),
        onPressed: () => _removeTag(t, type),
        backgroundColor: color.withValues(alpha: 0.08),
        side: BorderSide(color: color.withValues(alpha: 0.3)),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      )).toList(),
    );
  }
}