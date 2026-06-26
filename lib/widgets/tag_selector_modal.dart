// 标签选择弹窗，支持预设、已有和自定义标签的管理
import 'package:flutter/material.dart';

const _kPresetCategories = [
  {'title': '主体', 'tags': ['男性', '女性', '男女性交', '二次元', '脚', '其他', '无关内容']},
  {'title': '类别性质', 'tags': ['商业AV', '自拍', '原创', '合集收集', 'AI', '欧美', '黑人', 'SM', '男同', '羞辱']},
  {'title': '露出度', 'tags': ['不露', '露逼', '露屌', '露奶', '露脸']},
  {'title': '审查', 'tags': ['有马', 'AI去马', '无马']},
];

const _kInitialFixedTags = [
  '男娘', '女装', 'COS', 'Lolita', '露出', '白幼瘦', '白虎',
  '大奶', '贫乳', '广告', '阳痿', '盗图', '多人运动', '裸舞',
  '口交', '玩具', '足控', '内容混乱',
];

class TagSelectorModal extends StatefulWidget {
  final bool isOpen;
  final VoidCallback onClose;
  final void Function(Map<String, int> tags) onConfirm;
  final String username;
  final Map<String, dynamic> initialValues;

  const TagSelectorModal({
    super.key,
    required this.isOpen,
    required this.onClose,
    required this.onConfirm,
    required this.username,
    this.initialValues = const {},
  });

  @override
  State<TagSelectorModal> createState() => _TagSelectorModalState();
}

class _TagSelectorModalState extends State<TagSelectorModal> {
  Map<String, int> _tagScores = {};
  List<String> _displayOtherTags = [];
  final _customTagCtrl = TextEditingController();
  bool _isAddingTag = false;

  @override
  void initState() {
    super.initState();
    if (widget.isOpen) _init();
  }

  @override
  void didUpdateWidget(TagSelectorModal old) {
    super.didUpdateWidget(old);
    if (widget.isOpen && !old.isOpen) _init();
  }

  void _init() {
    _tagScores = {};
    for (final e in widget.initialValues.entries) {
      var score = (e.value as num).toInt();
      if (score > 1) score = 1;
      if (score < -1) score = -1;
      if (score != 0) _tagScores[e.key] = score;
    }
    _displayOtherTags = _kInitialFixedTags.toList();
    _customTagCtrl.clear();
    _isAddingTag = false;
  }

  @override
  void dispose() {
    _customTagCtrl.dispose();
    super.dispose();
  }

  void _handleTagClick(String tag) {
    setState(() {
      final cur = _tagScores[tag] ?? 0;
      int next;
      if (cur == 0) next = 1;
      else if (cur == 1) next = -1;
      else next = 0;
      if (next == 0) {
        _tagScores.remove(tag);
      } else {
        _tagScores[tag] = next;
      }
    });
  }

  void _handleAddCustomTag() {
    final tag = _customTagCtrl.text.trim();
    if (tag.isEmpty) {
      setState(() => _isAddingTag = false);
      return;
    }
    if (!_displayOtherTags.contains(tag)) {
      _displayOtherTags.add(tag);
    }
    _tagScores[tag] = 1;
    _customTagCtrl.clear();
    setState(() => _isAddingTag = false);
  }

  Color _chipBg(int? score) {
    if (score == 1) return Colors.blue.shade100;
    if (score == -1) return Colors.red.shade100;
    return Colors.grey.shade100;
  }

  Color _chipText(int? score) {
    if (score == 1) return Colors.blue.shade700;
    if (score == -1) return Colors.red.shade700;
    return Colors.grey.shade700;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isOpen) return const SizedBox.shrink();

    return Stack(
      children: [
        GestureDetector(
          onTap: widget.onClose,
          child: Container(color: Colors.black54),
        ),
        Center(
          child: Material(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: MediaQuery.of(context).size.width * 0.9,
              constraints: const BoxConstraints(maxHeight: 600),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('添加标签 @${widget.username}',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        IconButton(icon: const Icon(Icons.close), onPressed: widget.onClose),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      shrinkWrap: true,
                      children: [
                        for (final cat in _kPresetCategories) ...[
                          Text(cat['title'] as String,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6, runSpacing: 6,
                            children: (cat['tags'] as List<String>).map((t) => _buildChip(t)).toList(),
                          ),
                          const SizedBox(height: 16),
                        ],
                        const Text('其他 / 自定义',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6, runSpacing: 6,
                          children: [
                            ..._displayOtherTags.map((t) => _buildChip(t)),
                            if (_isAddingTag)
                              SizedBox(
                                width: 100,
                                child: TextField(
                                  autofocus: true,
                                  controller: _customTagCtrl,
                                  decoration: const InputDecoration(
                                    hintText: '输入...',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                  onSubmitted: (_) => _handleAddCustomTag(),
                                ),
                              )
                            else
                              ActionChip(
                                label: const Text('+ 添加', style: TextStyle(fontSize: 12)),
                                onPressed: () => setState(() => _isAddingTag = true),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(onPressed: widget.onClose, child: const Text('取消')),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () => widget.onConfirm(Map.from(_tagScores)),
                          child: const Text('确认保存'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChip(String tag) {
    final score = _tagScores[tag] ?? 0;
    return GestureDetector(
      onTap: () => _handleTagClick(tag),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: _chipBg(score),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _chipText(score).withValues(alpha: 0.3)),
        ),
        child: Text(tag, style: TextStyle(fontSize: 13, color: _chipText(score))),
      ),
    );
  }
}
