// 收藏列表组件，展示已收藏的用户并提供导入导出功能
import 'dart:async';

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
  Map<String, TwitterUser> _batchCache = const <String, TwitterUser>{};
  Future<Map<String, TwitterUser>>? _batchFuture;
  String _lastBatchKey = '';

  void _onStorageChanged() {
    if (mounted) {
      setState(() {
        _lastBatchKey = '';
        _batchFuture = null;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    StorageService.changes.addListener(_onStorageChanged);
  }

  @override
  void dispose() {
    StorageService.changes.removeListener(_onStorageChanged);
    super.dispose();
  }

  void _ensureBatchLoaded(List<String> visible) {
    final key = visible.join(',');
    if (key == _lastBatchKey || visible.isEmpty) return;
    _lastBatchKey = key;
    final fut = widget.api
        .getUsersBatchV2(visible)
        .catchError((_) => <String, TwitterUser>{});
    _batchFuture = fut;
    unawaited(fut.then((map) {
      if (!mounted || map.isEmpty) return;
      setState(() {
        _batchCache = <String, TwitterUser>{..._batchCache, ...map};
      });
    }));
  }

  @override
  Widget build(BuildContext context) {
    final rawUsernames = StorageService.getFavMap().keys.toList().reversed.toList();
    final allUsernames = rawUsernames
        .where((u) => u.isNotEmpty && !StorageService.isBlocked(u))
        .toList();
    final visible = allUsernames.take(_limit).toList();
    _ensureBatchLoaded(visible);

    if (rawUsernames.isEmpty && !_showImport) {
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

    // 必须是 Column，不能再套一层 ListView：本组件的父级（FavoritesTab）已经是
    // 纵向可滚动的 ListView，纵向 ListView 嵌纵向 ListView 会让内层拿到无界高度
    // → 内层渲染失败，收藏夹里"标题在、条目全空"（这就是"收藏了却看不见"）。
    // 滚动与下拉刷新都交给父级。
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (visible.isEmpty && !_showImport)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('没有收藏的用户', style: TextStyle(color: Colors.grey, fontSize: 13)),
            ),
          // 带 key：取消收藏后剩下的 tile 不会按位置错配、也不会重发元数据请求。
          ...visible.map((u) => _FavTile(
            key: ValueKey('fav_$u'),
            username: u,
            user: _batchCache[u],
            batchFuture: _batchFuture,
            api: widget.api,
            proxy: widget.proxy,
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
      _lastBatchKey = '';
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
  final TwitterUser? user;
  final Future<Map<String, TwitterUser>>? batchFuture;
  final TwitterApi api;
  final ProxyManager proxy;
  final VoidCallback? onUnfav;

  const _FavTile({
    super.key,
    required this.username,
    this.user,
    this.batchFuture,
    required this.api,
    required this.proxy,
    this.onUnfav,
  });

  @override
  State<_FavTile> createState() => _FavTileState();
}

class _FavTileState extends State<_FavTile> {
  Future<UserMetaData>? _meta;

  UserMetaData _metaFromBatchUser(TwitterUser u) {
    return UserMetaData(
      accountInfo: TwitterUser(
        username: u.username.isNotEmpty ? u.username : widget.username,
        nick: u.nick,
        avatar: u.avatar,
        totalUrls: u.totalUrls,
        tags: u.tags,
      ),
      timeline: const [],
      totalUrls: u.totalUrls ?? 0,
    );
  }

  /// 优先采用父级 `GET /api/twitter/v2/users/batch` 一次拿回的富卡片（含 nick、avatar、tags）；
  /// 若未命中或旧测试适配器未提供，则回退到并发拉取元数据与标签权重。
  Future<UserMetaData> _loadMetaWithTags(String username) async {
    final batchUser = widget.user;
    if (batchUser != null &&
        (batchUser.nick != null ||
            batchUser.avatar != null ||
            batchUser.tags.isNotEmpty)) {
      return _metaFromBatchUser(batchUser);
    }
    if (widget.batchFuture != null) {
      try {
        final batch = await widget.batchFuture!;
        final hit = batch[username];
        if (hit != null &&
            (hit.nick != null || hit.avatar != null || hit.tags.isNotEmpty)) {
          return _metaFromBatchUser(hit);
        }
      } catch (_) {}
    }

    final metaFuture = widget.api.getMetaData(username);
    final tagsFuture = widget.api
        .getTagWeights(username)
        .catchError((_) => const <String, int>{});
    final meta = await metaFuture;
    final fetchedTags = await tagsFuture;
    final mergedTags =
        fetchedTags.isNotEmpty ? fetchedTags : meta.accountInfo.tags;
    if (mergedTags.isEmpty) return meta;
    final info = meta.accountInfo;
    return UserMetaData(
      accountInfo: TwitterUser(
        username: info.username.isNotEmpty ? info.username : username,
        nick: info.nick,
        avatar: info.avatar,
        totalUrls: info.totalUrls,
        tags: mergedTags,
      ),
      timeline: meta.timeline,
      totalUrls: meta.totalUrls,
    );
  }

  @override
  void initState() {
    super.initState();
    _meta = _loadMetaWithTags(widget.username);
  }

  @override
  void didUpdateWidget(_FavTile old) {
    super.didUpdateWidget(old);
    if (old.username != widget.username ||
        (old.user == null && widget.user != null)) {
      _meta = _loadMetaWithTags(widget.username);
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
                onTap: () => setState(() => _meta = _loadMetaWithTags(widget.username)),
              ),
            ),
          );
        }
        final info = snapshot.data?.accountInfo ?? widget.user;
        final tags = info?.tags ?? const <String, int>{};
        if (StorageService.isBlocked(widget.username) ||
            (tags.isNotEmpty &&
                StorageService.shouldHideUser(widget.username, tags))) {
          return const SizedBox.shrink();
        }
        return ListTile(
          leading: ProxyAvatar(
            url: info?.avatar,
            fallbackText: widget.username.isNotEmpty
                ? widget.username[0].toUpperCase()
                : '?',
            proxy: widget.proxy,
            radius: 16,
          ),
          title: Text(info?.nick ?? widget.username),
          subtitle: Text('@${widget.username}'),
          onTap: () async {
            if (!snapshot.hasData) return;
            await Navigator.push(context, PageRouteBuilder(
              transitionDuration: const Duration(milliseconds: 300),
              reverseTransitionDuration: const Duration(milliseconds: 300),
              pageBuilder: (_, a, __) => UserDetailScreen(
                profile: snapshot.data!,
                proxy: widget.proxy,
                tagBrowse: null,
                api: widget.api,
              ),
              transitionsBuilder: (_, a, __, child) {
                final curved = CurvedAnimation(parent: a, curve: Curves.easeInOutCubic);
                return FadeTransition(
                  opacity: curved,
                  child: Transform.scale(
                    scale: 0.95 + 0.05 * curved.value,
                    child: child,
                  ),
                );
              },
            ));
            widget.onUnfav?.call();
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
