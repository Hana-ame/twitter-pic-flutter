// browse_history_screen.dart
// 最近浏览历史页面：展示最近访问过的推主，支持搜索过滤、单条移除、清空历史及快速回访。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../widgets/proxy_avatar.dart';
import '../widgets/tag_browse.dart';
import 'user_detail_screen.dart';

class BrowseHistoryScreen extends StatefulWidget {
  final ProxyManager proxy;
  final TwitterApi? api;
  final TagBrowseRequest? tagBrowse;

  const BrowseHistoryScreen({
    super.key,
    required this.proxy,
    this.api,
    this.tagBrowse,
  });

  @override
  State<BrowseHistoryScreen> createState() => _BrowseHistoryScreenState();
}

class _BrowseHistoryScreenState extends State<BrowseHistoryScreen> {
  late final TwitterApi _api;
  late final bool _ownsApi;
  String _filter = '';
  final TextEditingController _filterCtrl = TextEditingController();

  void _onStorageChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? TwitterApi();
    _ownsApi = widget.api == null;
    StorageService.changes.addListener(_onStorageChanged);
  }

  @override
  void dispose() {
    StorageService.changes.removeListener(_onStorageChanged);
    _filterCtrl.dispose();
    if (_ownsApi) _api.dispose();
    super.dispose();
  }

  String _formatTime(int visitedAtMs) {
    if (visitedAtMs <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(visitedAtMs);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    final y = dt.year;
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空浏览历史'),
        content: const Text('确定要清空所有最近浏览记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      StorageService.clearBrowseHistory();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清空浏览历史')),
      );
    }
  }

  Future<void> _openUser(BrowseHistoryEntry entry) async {
    final nav = Navigator.of(context);
    final profile = UserMetaData(
      accountInfo: TwitterUser(
        username: entry.username,
        nick: entry.nick,
        avatar: entry.avatar,
      ),
      timeline: const [],
      totalUrls: 0,
    );
    await nav.push(
      MaterialPageRoute(
        builder: (_) => UserDetailScreen(
          profile: profile,
          proxy: widget.proxy,
          api: _api,
          tagBrowse: widget.tagBrowse == null
              ? null
              : (String tag, {void Function(bool)? callback}) {
                  final ok = widget.tagBrowse!(tag, callback: callback);
                  if (ok && nav.canPop()) {
                    nav.pop();
                  }
                  return ok;
                },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final all = StorageService.getBrowseHistory()
        .where((e) => !StorageService.isBlocked(e.username))
        .toList();
    final q = _filter.trim().toLowerCase();
    final filtered = q.isEmpty
        ? all
        : all.where((e) {
            final u = e.username.toLowerCase();
            final n = (e.nick ?? '').toLowerCase();
            return u.contains(q) || n.contains(q);
          }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(all.isEmpty ? '浏览历史' : '浏览历史 (${all.length})'),
        actions: [
          if (all.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空历史',
              onPressed: _confirmClearAll,
            ),
        ],
      ),
      body: all.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history_outlined, size: 56, color: Colors.grey),
                  SizedBox(height: 12),
                  Text('暂无浏览历史',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  SizedBox(height: 4),
                  Text('点进推主详情页后会自动记录在这里，方便随时回看',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                ],
              ),
            )
          : Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: TextField(
                    controller: _filterCtrl,
                    onChanged: (v) => setState(() => _filter = v),
                    decoration: InputDecoration(
                      hintText: '在浏览历史中搜索用户名或昵称…',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: _filter.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () {
                                _filterCtrl.clear();
                                setState(() => _filter = '');
                              },
                            )
                          : null,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(
                          child: Text('没有匹配的浏览记录',
                              style:
                                  TextStyle(color: Colors.grey, fontSize: 14)),
                        )
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final item = filtered[i];
                            final isFav = StorageService.isFav(item.username);
                            final timeText = _formatTime(item.visitedAtMs);
                            return ListTile(
                              key: ValueKey('history_${item.username}'),
                              leading: ProxyAvatar(
                                url: item.avatar,
                                fallbackText: item.username.isNotEmpty
                                    ? item.username[0].toUpperCase()
                                    : '?',
                                proxy: widget.proxy,
                                radius: 18,
                              ),
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      item.nick ?? item.username,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ),
                                  if (isFav) ...[
                                    const SizedBox(width: 6),
                                    const Icon(Icons.favorite,
                                        color: Colors.red, size: 15),
                                  ],
                                ],
                              ),
                              subtitle: Text(
                                timeText.isEmpty
                                    ? '@${item.username}'
                                    : '@${item.username} · $timeText',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey),
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                tooltip: '移除此条记录',
                                onPressed: () => StorageService
                                    .removeBrowseHistory(item.username),
                              ),
                              onTap: () => _openUser(item),
                              onLongPress: () {
                                showModalBottomSheet(
                                  context: context,
                                  builder: (ctx) => SafeArea(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 12),
                                          child: Text('@${item.username}',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                        ),
                                        ListTile(
                                          leading: Icon(
                                            isFav
                                                ? Icons.favorite
                                                : Icons.favorite_border,
                                            color:
                                                isFav ? Colors.red : Colors.grey,
                                          ),
                                          title:
                                              Text(isFav ? '取消收藏' : '加入收藏'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            StorageService.toggleFav(
                                                item.username);
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(Icons.copy),
                                          title: const Text('复制用户名'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            Clipboard.setData(ClipboardData(
                                                text: '@${item.username}'));
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(SnackBar(
                                                    content: Text(
                                                        '已复制 @${item.username}')));
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(
                                              Icons.delete_outline,
                                              color: Colors.red),
                                          title: const Text('从历史记录移除'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            StorageService.removeBrowseHistory(
                                                item.username);
                                          },
                                        ),
                                        const SizedBox(height: 8),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
