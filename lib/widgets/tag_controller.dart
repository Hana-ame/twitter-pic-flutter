// 标签控制页面：管理高亮标签、屏蔽标签、Gay 专属标签以及已屏蔽账号（block-map）
import 'package:flutter/material.dart';

import '../services/storage_service.dart';

const _kDefaultBlockTags = [
  '无关内容',
];

class TagControllerScreen extends StatefulWidget {
  const TagControllerScreen({super.key});

  @override
  State<TagControllerScreen> createState() => _TagControllerScreenState();
}

class _TagControllerScreenState extends State<TagControllerScreen> {
  final _inputCtrl = TextEditingController();
  final _blockUserCtrl = TextEditingController();
  List<String> _highlight = [];
  List<String> _block = [];
  List<String> _gayTags = [];
  List<String> _blockedUsers = [];
  bool _gayMode = false;

  @override
  void initState() {
    super.initState();
    _inputCtrl.addListener(_onInputChanged);
    _blockUserCtrl.addListener(_onInputChanged);
    _load();
  }

  // 原实现按钮的禁用条件只在 build 时求值、输入不触发重建，
  // 导致打字后"高亮/屏蔽"按钮永远是灰的（只能按回车提交）。
  void _onInputChanged() {
    if (mounted) setState(() {});
  }

  void _load() {
    _gayMode = StorageService.isGayMode();
    _gayTags = StorageService.getGayTags();
    _blockedUsers = StorageService.getBlockedUsers();
    final rules = StorageService.getTagRules();
    _highlight = (rules['highlight'] as List?)?.cast<String>() ?? [];
    final storedBlock = (rules['block'] as List?)?.cast<String>() ?? [];
    // 判据必须是 **`containsKey` 而不是 `isEmpty`**。
    //
    // 两者在「用户主动清空了屏蔽列表」时都成立，但含义完全相反：
    //   - 键不存在 = 从来没配过 → 给一份默认（首次体验）
    //   - 键存在但为空 = 用户明确表示「一个都不要」→ 必须尊重
    if (rules.containsKey('block')) {
      _block = storedBlock;
    } else {
      // 首次进入：给一份出厂值并**立即落盘**。
      _block = _kDefaultBlockTags.toList();
      _save();
    }
  }

  void _save() {
    StorageService.setTagRules({
      'highlight': _highlight,
      'block': _block,
    });
  }

  void _addTag(String type) {
    final tag = _inputCtrl.text.trim().replaceFirst(RegExp(r'^#+'), '');
    if (tag.isEmpty) return;
    setState(() {
      if (type == 'highlight') {
        _block.remove(tag);
        if (!_highlight.contains(tag)) _highlight.add(tag);
        _save();
      } else if (type == 'block') {
        _highlight.remove(tag);
        if (!_block.contains(tag)) _block.add(tag);
        _save();
      } else if (type == 'gay') {
        StorageService.addGayTag(tag);
        _gayTags = StorageService.getGayTags();
      }
      _inputCtrl.clear();
    });
  }

  void _removeTag(String tag, String type) {
    setState(() {
      if (type == 'highlight') {
        _highlight.remove(tag);
        _save();
      } else if (type == 'block') {
        _block.remove(tag);
        _save();
      } else if (type == 'gay') {
        StorageService.removeGayTag(tag);
        _gayTags = StorageService.getGayTags();
      }
    });
  }

  void _resetGayTags() {
    setState(() {
      StorageService.resetGayTags();
      _gayTags = StorageService.getGayTags();
    });
  }

  void _addBlockedUser() {
    final clean =
        _blockUserCtrl.text.trim().replaceFirst(RegExp(r'^@+'), '').trim();
    if (clean.isEmpty) return;
    setState(() {
      StorageService.addBlockedUser(clean);
      _blockedUsers = StorageService.getBlockedUsers();
      _blockUserCtrl.clear();
    });
  }

  void _removeBlockedUser(String username) {
    setState(() {
      StorageService.removeBlockedUser(username);
      _blockedUsers = StorageService.getBlockedUsers();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已取消屏蔽 @$username'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _clearBlockedUsers() {
    setState(() {
      StorageService.clearBlockedUsers();
      _blockedUsers = StorageService.getBlockedUsers();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已清空全部屏蔽账号'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _inputCtrl.removeListener(_onInputChanged);
    _blockUserCtrl.removeListener(_onInputChanged);
    _inputCtrl.dispose();
    _blockUserCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasInput = _inputCtrl.text.trim().isNotEmpty;
    final hasBlockUserInput = _blockUserCtrl.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('标签管理')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              color: Colors.purple.shade50,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: Colors.purple.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    title: const Row(
                      children: [
                        Text('🌈 ', style: TextStyle(fontSize: 16)),
                        Text('Gay 模式', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      ],
                    ),
                    subtitle: Text(
                      _gayMode
                          ? '已开启：只显示包含【${_gayTags.join(" / ")}】的账号'
                          : '已关闭：隐藏包含【${_gayTags.join(" / ")}】的账号',
                      style: TextStyle(fontSize: 11, color: Colors.purple.shade800),
                    ),
                    value: _gayMode,
                    activeColor: Colors.purple,
                    onChanged: (val) {
                      setState(() {
                        _gayMode = val;
                        StorageService.setGayMode(val);
                      });
                    },
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Gay 专属标签 (${_gayTags.length})',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.purple.shade900),
                            ),
                            TextButton(
                              onPressed: _resetGayTags,
                              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                              child: const Text('恢复默认', style: TextStyle(fontSize: 11)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (_gayTags.isEmpty)
                          const Text('无 Gay 标签', style: TextStyle(color: Colors.grey, fontSize: 12))
                        else
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: _gayTags.map((t) => ActionChip(
                              label: Text(t, style: const TextStyle(fontSize: 12)),
                              avatar: Icon(Icons.close, size: 14, color: Colors.purple.shade700),
                              onPressed: () => _removeTag(t, 'gay'),
                              backgroundColor: Colors.purple.shade100,
                              side: BorderSide(color: Colors.purple.shade300),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            )).toList(),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
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
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: hasInput ? () => _addTag('gay') : null,
                    icon: const Text('🌈', style: TextStyle(fontSize: 12)),
                    label: const Text('设为Gay'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.purple.shade50,
                      foregroundColor: Colors.purple.shade800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '高亮：命中的标签加星标强调，详情页与标签列表都会显示。\n'
              '屏蔽：账号带这些标签时，在用户列表 / 标签列表 / 收藏夹里不再出现；'
              '直接打开其详情页时，页面顶部仍会给出提示条（方便确认是哪个标签命中的）。\n'
              'Gay 模式开启时不按屏蔽标签过滤，只按 Gay 标签取反筛选。',
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
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildSectionHeader(
                  Icons.person_off_outlined,
                  Colors.deepOrange,
                  '已屏蔽账号',
                  _blockedUsers.length,
                ),
                if (_blockedUsers.isNotEmpty)
                  TextButton(
                    onPressed: _clearBlockedUsers,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: Colors.red,
                    ),
                    child: const Text('全部解除', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _blockUserCtrl,
                    decoration: InputDecoration(
                      hintText: '输入要屏蔽的 @用户名...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      prefixIcon: const Icon(Icons.alternate_email, size: 18),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    onSubmitted: (_) => _addBlockedUser(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: hasBlockUserInput ? _addBlockedUser : null,
                  icon: const Icon(Icons.block, size: 16),
                  label: const Text('屏蔽账号'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.deepOrange.shade50,
                    foregroundColor: Colors.deepOrange.shade800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_blockedUsers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '无已屏蔽账号',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _blockedUsers
                    .map(
                      (u) => ActionChip(
                        key: ValueKey('blocked_user_$u'),
                        label: Text('@$u', style: const TextStyle(fontSize: 12)),
                        avatar: const Icon(
                          Icons.close,
                          size: 14,
                          color: Colors.deepOrange,
                        ),
                        onPressed: () => _removeBlockedUser(u),
                        backgroundColor:
                            Colors.deepOrange.withValues(alpha: 0.08),
                        side: BorderSide(
                          color: Colors.deepOrange.withValues(alpha: 0.3),
                        ),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    )
                    .toList(),
              ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
      IconData icon, Color color, String title, int count) {
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

  Widget _buildTagList(List<String> tags, Color color, String type) {
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