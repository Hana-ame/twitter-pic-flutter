// Emoji 排行页面：展示各时间段的投票榜单，支持周期筛选、收藏状态显示与长按快捷操作
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/storage_service.dart';

class RankingScreen extends StatefulWidget {
  final TwitterApi api;
  final void Function(UserMetaData) onSelectUser;

  const RankingScreen({super.key, required this.api, required this.onSelectUser});

  @override
  State<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends State<RankingScreen> {
  Map<String, EmojiPeriodData>? _data;
  String? _activeEmoji;
  String _periodFilter = 'all'; // 'all' | 'day' | 'week' | 'month'
  bool _loading = true;
  String? _error;
  String? _loadingUser;

  void _onStorageChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    StorageService.changes.addListener(_onStorageChanged);
    _load();
  }

  @override
  void dispose() {
    StorageService.changes.removeListener(_onStorageChanged);
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.getRanking();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        final keys = data.keys.toList();
        if (keys.isNotEmpty && (_activeEmoji == null || !data.containsKey(_activeEmoji))) {
          _activeEmoji = keys[0];
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              const Text('排行榜加载失败',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              SelectableText(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_data == null || _data!.isEmpty) {
      return const Center(child: Text('暂无排行数据'));
    }

    final currentPeriod = _activeEmoji != null ? _data![_activeEmoji] : null;

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: _data!.keys.map((emoji) => GestureDetector(
                onTap: () => setState(() => _activeEmoji = emoji),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _activeEmoji == emoji ? Colors.blue.shade50 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: _activeEmoji == emoji ? Border.all(color: Colors.blue.shade200) : null,
                  ),
                  child: Center(child: Text(emoji, style: const TextStyle(fontSize: 22))),
                ),
              )).toList(),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              alignment: WrapAlignment.center,
              children: [
                _buildPeriodChip('all', '全部榜单'),
                _buildPeriodChip('day', '日榜'),
                _buildPeriodChip('week', '周榜'),
                _buildPeriodChip('month', '月榜'),
              ],
            ),
            const SizedBox(height: 10),
            if (currentPeriod != null)
              Column(
                children: [
                  if (_periodFilter == 'all' || _periodFilter == 'day')
                    _buildList('日榜', currentPeriod.day),
                  if (_periodFilter == 'all' || _periodFilter == 'week')
                    _buildList('周榜', currentPeriod.week),
                  if (_periodFilter == 'all' || _periodFilter == 'month')
                    _buildList('月榜', currentPeriod.month),
                ],
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildPeriodChip(String key, String label) {
    final selected = _periodFilter == key;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => setState(() => _periodFilter = key),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  Widget _buildList(String title, List<RankingEntry> entries) {
    final visibleEntries = entries
        .where((e) =>
            e.username.isNotEmpty && !StorageService.isBlocked(e.valueUsername))
        .take(10)
        .toList();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (visibleEntries.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text('暂无上榜数据', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ...visibleEntries.asMap().entries.map((e) {
            final username = e.value.username;
            final isRowLoading = _loadingUser == username;
            final isFav = StorageService.isFav(username);
            return ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 12,
                backgroundColor: e.key == 0
                    ? Colors.amber
                    : e.key == 1
                        ? Colors.grey
                        : e.key == 2
                            ? Colors.orange
                            : Colors.grey.shade200,
                child: Text('${e.key + 1}',
                    style: const TextStyle(fontSize: 10, color: Colors.white)),
              ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      '@$username',
                      style: const TextStyle(fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isFav) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.favorite, color: Colors.red, size: 14),
                  ],
                ],
              ),
              trailing: isRowLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('${e.value.votes}票',
                      style: const TextStyle(fontSize: 12, color: Colors.blue)),
              onTap: () async {
                if (_loadingUser != null) return;
                setState(() => _loadingUser = username);
                try {
                  final profile = await widget.api.getMetaData(username);
                  if (mounted && profile.accountInfo.username.isNotEmpty) {
                    widget.onSelectUser(profile);
                  }
                } catch (_) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('加载用户失败: $username')),
                    );
                  }
                } finally {
                  if (mounted) setState(() => _loadingUser = null);
                }
              },
              onLongPress: () {
                showModalBottomSheet(
                  context: context,
                  builder: (ctx) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text('@$username',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        ListTile(
                          leading: Icon(
                            isFav ? Icons.favorite : Icons.favorite_border,
                            color: isFav ? Colors.red : Colors.grey,
                          ),
                          title: Text(isFav ? '取消收藏' : '加入收藏'),
                          onTap: () {
                            Navigator.pop(ctx);
                            StorageService.toggleFav(username);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.copy),
                          title: const Text('复制用户名'),
                          onTap: () {
                            Navigator.pop(ctx);
                            Clipboard.setData(
                                ClipboardData(text: '@$username'));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('已复制 @$username')),
                            );
                          },
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                );
              },
            );
          }),
        ],
      ),
    );
  }
}

extension on RankingEntry {
  String get valueUsername => username;
}
