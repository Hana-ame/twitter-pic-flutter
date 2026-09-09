// 收藏列表组件，展示已收藏的用户并提供导入导出功能
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/storage_service.dart';
import '../api/twitter_api.dart';
import '../models/user.dart';
import '../screens/user_detail_screen.dart';
import '../services/proxy_manager.dart';
import 'proxy_avatar.dart';
import 'horizontal_button_row.dart';

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

    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _limit = 10);
      },
      child: ListView(
        children: [
          ...visible.map((u) => _FavTile(username: u, api: widget.api, proxy: widget.proxy)),
          if (_limit < allUsernames.length)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => setState(() => _limit += 20),
                  child: const Text('加载更多'),
                ),
              ),
            ),
          HorizontalButtonRow(buttons: [
            ElevatedButton(
              onPressed: _handleExport,
              style: ElevatedButton.styleFrom(surfaceTintColor: Colors.transparent),
              child: const Text('导出收藏'),
            ),
            ElevatedButton(
              onPressed: () => setState(() => _showImport = !_showImport),
              style: ElevatedButton.styleFrom(surfaceTintColor: Colors.transparent),
              child: Text(_showImport ? '取消导入' : '导入收藏'),
            ),
          ]),
          if (_showImport)
            Column(
              children: [
                TextField(
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: '每行一个URL',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _importText = v,
                ),
                ElevatedButton(
                  onPressed: _handleImport,
                  child: const Text('确认导入'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  void _handleExport() {
    final text = StorageService.getFavMap().keys.map((k) => 'https://x.moonchan.xyz/$k').join('\n');
    _copyToClipboard(text);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
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
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('导入成功')));
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
  }
}

class _FavTile extends StatefulWidget {
  final String username;
  final TwitterApi api;
  final ProxyManager proxy;

  const _FavTile({required this.username, required this.api, required this.proxy});

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
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => UserDetailScreen(profile: snapshot.data!, proxy: widget.proxy),
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
                        setState(() {});
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
