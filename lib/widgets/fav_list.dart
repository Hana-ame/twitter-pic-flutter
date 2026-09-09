// 收藏列表组件，展示已收藏的用户并提供导入导出功能
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/storage_service.dart';
import '../api/twitter_api.dart';
import '../models/user.dart';
import '../screens/user_detail_screen.dart';
import '../services/proxy_manager.dart';
import 'proxy_avatar.dart';

class FavList extends StatefulWidget {
  final TwitterApi api;
  final ProxyManager proxy;

  const FavList({super.key, required this.api, required this.proxy});

  @override
  State<FavList> createState() => _FavListState();
}

class _FavListState extends State<FavList> {
  int _limit = 10;
  String _importText = '';
  bool _showImport = false;

  @override
  Widget build(BuildContext context) {
    final allUsernames = StorageService.getFavMap().keys.toList().reversed.toList();
    final visible = allUsernames.take(_limit).toList();

    if (allUsernames.isEmpty && !_showImport) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.favorite_border, size: 56, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('收藏夹为空', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('在用户列表中长按用户即可收藏', style: TextStyle(fontSize: 13, color: Colors.grey)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: const Color(0xFF4F6CFF),
      backgroundColor: Colors.white,
      onRefresh: () async {
        setState(() => _limit = 10);
      },
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          if (visible.isEmpty && !_showImport)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('没有收藏的用户', style: TextStyle(color: Colors.grey, fontSize: 13)),
            ),
          ...visible.map((u) => _FavTile(
            username: u, api: widget.api, proxy: widget.proxy,
            onUnfav: () => setState(() {}),
          )),
          if (_limit < allUsernames.length)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _limit += 20),
                icon: const Icon(Icons.expand_more, size: 16),
                label: Text('显示更多 (${allUsernames.length - _limit} 个)'),
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _handleExport,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('导出'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _showImport = !_showImport),
                  icon: const Icon(Icons.paste, size: 16),
                  label: Text(_showImport ? '取消' : '导入'),
                ),
              ],
            ),
          ),
          if (_showImport)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                children: [
                  TextField(
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: '每行一个URL',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12),
                    ),
                    onChanged: (v) => _importText = v,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _handleImport,
                    icon: const Icon(Icons.check),
                    label: const Text('确认导入'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _handleExport() {
    final map = StorageService.getFavMap();
    if (map.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Row(children: [Icon(Icons.info_outline, size: 18), SizedBox(width: 8), Text('没有可导出的收藏')])),
      );
      return;
    }
    final text = map.keys.map((k) => 'https://x.moonchan.xyz/$k').join('\n');
    _copyToClipboard(text);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Row(children: [Icon(Icons.check_circle, size: 18), SizedBox(width: 8), Text('已复制到剪贴板')])),
    );
  }

  void _handleImport() {
    if (_importText.trim().isEmpty) return;
    final map = StorageService.getFavMap();
    for (final line in _importText.split('\n')) {
      final parts = line.trim().replaceAll(RegExp(r'/+$'), '').split('/');
      final key = parts.last;
      if (key.isNotEmpty && key != 'http:' && key != 'https:') {
        map[key] = true;
      }
    }
    StorageService.setFavMap(map);
    setState(() {
      _importText = '';
      _showImport = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Row(children: [Icon(Icons.check_circle, size: 18), SizedBox(width: 8), Text('导入成功')])),
    );
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
  }
}

class _FavTile extends StatefulWidget {
  final String username;
  final TwitterApi api;
  final ProxyManager proxy;
  final VoidCallback? onUnfav;

  const _FavTile({
    required this.username,
    required this.api,
    required this.proxy,
    this.onUnfav,
  });

  @override
  State<_FavTile> createState() => _FavTileState();
}

class _FavTileState extends State<_FavTile> {
  Future<UserMetaData>? _meta;

  @override
  void initState() {
    super.initState();
    _meta = widget.api.getMetaData(widget.username);
  }

  @override
  void didUpdateWidget(_FavTile old) {
    super.didUpdateWidget(old);
    // 原实现在 build 里直接 new FutureBuilder future，父组件任意 setState
    // （导入/导出/加载更多）都会让所有可见 tile 重发请求。
    if (old.username != widget.username) {
      _meta = widget.api.getMetaData(widget.username);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UserMetaData>(
      future: _meta,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: Colors.red.withValues(alpha: 0.3)),
              ),
              child: ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.red.withValues(alpha: 0.1),
                  child: const Icon(Icons.error, size: 18, color: Colors.red),
                ),
                title: Text(widget.username, style: const TextStyle(fontSize: 14)),
                subtitle: const Text('加载失败，点击重试', style: TextStyle(color: Colors.red, fontSize: 11)),
                onTap: () => setState(() => _meta = widget.api.getMetaData(widget.username)),
              ),
            ),
          );
        }
        final info = snapshot.data?.accountInfo;
        return ListTile(
          leading: ProxyAvatar(
            url: info?.avatar,
            fallbackText: widget.username[0].toUpperCase(),
            proxy: widget.proxy,
            radius: 16,
          ),
          title: Text(info?.nick ?? widget.username),
          subtitle: Text('@${widget.username}'),
          onTap: () {
            if (snapshot.hasData) {
              Navigator.push(context, PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 300),
                reverseTransitionDuration: const Duration(milliseconds: 300),
                pageBuilder: (_, a, __) => UserDetailScreen(profile: snapshot.data!, proxy: widget.proxy),
                transitionsBuilder: (_, a, __, child) {
                  final curved = Curves.easeInOutCubic.transform(a);
                  return FadeTransition(
                    opacity: curved,
                    child: Transform.scale(
                      scale: 0.95 + 0.05 * curved,
                      child: child,
                    ),
                  );
                },
              ));
            }
          },
          onLongPress: () {
            showModalBottomSheet(
              context: context,
              builder: (ctx) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('用户操作', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.favorite, color: Colors.red),
                      title: const Text('取消收藏'),
                      onTap: () {
                        Navigator.pop(ctx);
                        StorageService.toggleFav(widget.username);
                        widget.onUnfav?.call();
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
    );
  }
}
