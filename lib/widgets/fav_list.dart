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
        // 收藏夹此前**完全不过滤**（连用户名屏蔽都没应用）——用户屏蔽了某个
        // 账号，它照样出现在收藏里。统一走 shouldHideUser，与其它列表同口径。
        //
        // 这里只能拿到 _meta.accountInfo.tags：收藏项是先拉元数据再决定显不
        // 显示的，所以标签级规则（屏蔽标签 / Gay 模式）在这一步才有数据可用。
        if (StorageService.shouldHideUser(
            widget.username, snapshot.data?.accountInfo.tags ?? const {})) {
          return const SizedBox.shrink();
        }
        return ListTile(
          leading: ProxyAvatar(
            url: info?.avatar,
            fallbackText: widget.username[0].toUpperCase(),
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
              // ⚠️ `tagBrowse: null` 是**显式决定**，不是漏传（UserDetailScreen.tagBrowse
              // 是 required，漏传编译不过，代码里不存在「忘了传」这种可能）。
              //
              // 详情页点标签时会把请求**递回**背后那个用户列表页、就地切换、然后
              // pop 自己（widgets/tag_browse.dart 的说明）。收藏页背后**没有**
              // 列表页——`FavoritesTab` 与 `UserListScreen` 是 IndexedStack 里两个
              // 平级的 Tab、彼此不可见。所以「不能就地切」在这里是**合法且正确**
              // 的状态：能递回的只有 UserListScreen，而让它从另一个 Tab 的
              // Scaffold 里起作用等于跨 Tab 操纵，会造出「用户在收藏 Tab、标签结果
              // 却出现在用户 Tab」这种比一句提示更糟的状态。另一条路是在收藏页把
              // 标签查找**再做一份**，那是 tag_browse.dart 开头已否掉的方案
              // （同一件事两份实现，必然各自漂移）。
              //
              // 那为什么保留这个入口？因为它承载用户可见的必要反馈：详情页必须
              // 明确说「此页不支持标签就地查看，请从用户列表进入」，点了不能静默
              // 无反应。test/fav_tag_browse_contract_test.dart 走真实点击路径钉住
              // 三条：提示出现 / 没被 pop / 没多发一个标签反查请求。
              pageBuilder: (_, a, __) => UserDetailScreen(
                profile: snapshot.data!,
                proxy: widget.proxy,
                tagBrowse: null,
                // 透传 api：详情页默认**自建**一个 TwitterApi 打真实网络，于是
                // 它的标签区与外面这个实例无关——注入假适配器的测试永远构造不出
                // 可点的标签区（tag_same_page_test 靠显式注入才跑得起来）。
                // 复用同一个实例，也让这一页的请求走同一条连接与同一份缓存。
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
            // 详情页里可能取消收藏：返回后让父列表重新读取收藏表，
            // 否则该项会一直留在收藏夹里。
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
