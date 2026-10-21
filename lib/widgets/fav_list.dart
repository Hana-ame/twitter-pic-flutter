// 收藏列表组件，展示已收藏的用户并提供搜索筛选、排序切换及导入导出功能
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/storage_service.dart';
import '../api/twitter_api.dart';
import '../models/user.dart';
import '../screens/user_detail_screen.dart';
import '../services/proxy_manager.dart';
import 'proxy_avatar.dart';

/// 解析一行导入文本，提取合法用户名。
///
/// 兼容格式：
///   - `https://x.moonchan.xyz/alice`
///   - `https://x.com/alice?s=20` / `https://twitter.com/alice`
///   - `@alice`
///   - `alice`
String? parseImportedUsername(String rawLine) {
  var s = rawLine.trim();
  if (s.isEmpty) return null;
  // 去掉 query / fragment
  final qIdx = s.indexOf('?');
  if (qIdx >= 0) s = s.substring(0, qIdx);
  final hIdx = s.indexOf('#');
  if (hIdx >= 0) s = s.substring(0, hIdx);
  s = s.replaceAll(RegExp(r'/+$'), '').trim();
  if (s.isEmpty) return null;
  final parts = s.split('/');
  final last = parts.last.trim().replaceFirst(RegExp(r'^@+'), '').trim();
  if (last.isEmpty || last == 'http:' || last == 'https:') return null;
  return last;
}

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
  String _filterQuery = '';
  bool _sortAlpha = false;
  final TextEditingController _filterCtrl = TextEditingController();

  void _onStorageChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    StorageService.changes.addListener(_onStorageChanged);
  }

  @override
  void dispose() {
    StorageService.changes.removeListener(_onStorageChanged);
    _filterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rawUsernames = StorageService.getFavMap().keys.toList().reversed.toList();
    final allUsernames = rawUsernames
        .where((u) => u.isNotEmpty && !StorageService.isBlocked(u))
        .toList();
    if (_sortAlpha) {
      allUsernames.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
    final q = _filterQuery.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase();
    final filteredUsernames = q.isEmpty
        ? allUsernames
        : allUsernames.where((u) => u.toLowerCase().contains(q)).toList();
    final visible = filteredUsernames.take(_limit).toList();

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
          if (allUsernames.length >= 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _filterCtrl,
                      onChanged: (v) => setState(() => _filterQuery = v),
                      decoration: InputDecoration(
                        hintText: '搜索已收藏的用户名 (${allUsernames.length})…',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _filterQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: () {
                                  _filterCtrl.clear();
                                  setState(() => _filterQuery = '');
                                },
                              )
                            : null,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: Icon(
                      _sortAlpha ? Icons.sort_by_alpha : Icons.schedule,
                      size: 15,
                    ),
                    label: Text(
                      _sortAlpha ? 'A-Z' : '最新',
                      style: const TextStyle(fontSize: 11),
                    ),
                    onPressed: () => setState(() => _sortAlpha = !_sortAlpha),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ),
            ),
          if (visible.isEmpty && !_showImport)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                q.isNotEmpty ? '没有匹配的收藏用户' : '没有收藏的用户',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
          // 带 key：取消收藏后剩下的 tile 不会按位置错配、也不会重发元数据请求。
          ...visible.map((u) => _FavTile(
            key: ValueKey('fav_$u'),
            username: u, api: widget.api, proxy: widget.proxy,
            onUnfav: () => setState(() {}),
          )),
          if (_limit < filteredUsernames.length)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _limit += 20),
                icon: const Icon(Icons.expand_more, size: 16),
                label: Text('显示更多 (${filteredUsernames.length - _limit} 个)'),
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
                      hintText: '每行一个URL或@用户名',
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
      final key = parseImportedUsername(line);
      if (key != null && key.isNotEmpty) {
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
    super.key,
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

  /// 并发拉取元数据与标签权重：`<user>.json.gz` 的 `account_info` 不含 `tags`
  /// 字段，若直接拿 `accountInfo.tags`（恒为空 Map）送进 `shouldHideUser`，
  /// 会导致收藏夹里「屏蔽标签」完全失效、且开启 Gay 模式时所有收藏项被误判隐藏。
  Future<UserMetaData> _loadMetaWithTags(String username) async {
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
    if (old.username != widget.username) {
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
        final info = snapshot.data?.accountInfo;
        final tags = info?.tags ?? const <String, int>{};
        // 统一走 shouldHideUser，与其它列表同口径。
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
              // ⚠️ `tagBrowse: null` 是**显式决定**，不是漏传（由 test/fav_tag_browse_contract_test.dart 钉住）。
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
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text('@${widget.username}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
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
                    ListTile(
                      leading: const Icon(Icons.copy),
                      title: const Text('复制用户名'),
                      onTap: () {
                        Navigator.pop(ctx);
                        Clipboard.setData(
                            ClipboardData(text: '@${widget.username}'));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已复制 @${widget.username}')),
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.block, color: Colors.deepOrange),
                      title: const Text('屏蔽该用户'),
                      onTap: () {
                        Navigator.pop(ctx);
                        StorageService.addBlockedUser(widget.username);
                        widget.onUnfav?.call();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已屏蔽 @${widget.username}'),
                            action: SnackBarAction(
                              label: '撤销',
                              onPressed: () => StorageService
                                  .removeBlockedUser(widget.username),
                            ),
                          ),
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
      },
    );
  }
}
