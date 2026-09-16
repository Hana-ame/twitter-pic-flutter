// 用户列表页面：显示所有用户并支持搜索（用户名/昵称/`#标签` 三路）、收藏切换
import 'dart:async';

import 'package:flutter/material.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../widgets/proxy_avatar.dart';
import '../widgets/search_bar.dart';
import 'tag_user_list_screen.dart';
import 'user_detail_screen.dart';

class UserListScreen extends StatefulWidget {
  final ProxyManager proxy;

  /// 仅供测试注入（配 `TwitterApi(adapter: ...)` 假适配器）；生产调用点
  /// （main.dart）不传，页面自建实例并负责 dispose。
  final TwitterApi? api;

  const UserListScreen({super.key, required this.proxy, this.api});

  @override
  State<UserListScreen> createState() => UserListScreenState();
}

class UserListScreenState extends State<UserListScreen> {
  late final TwitterApi _api;
  bool _ownsApi = false;
  List<TwitterUser> _users = [];
  bool _loading = true;
  String? _error;
  String _search = '';
  /// true = 搜索词带 `#` 前缀，**只走 tag 路**（"添加此用户"也无意义，隐藏）。
  bool _searchByTag = false;
  // 搜索防抖 + 结果 future 复用：原实现每次 build（每个按键）都新建
  // FutureBuilder future，狂发请求且乱序返回会显示错误结果。
  Timer? _debounce;
  /// 当前已生效的搜索键：tag 模式带 `#` 前缀，空串 = 无搜索。
  /// 用"键"而不是裸文本比较，`#foo` 与 `foo` 文本相同但查询完全不同。
  String _appliedQuery = '';
  Future<SearchMergeResult>? _searchFuture;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? TwitterApi();
    _ownsApi = widget.api == null;
    _load();
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      final raw = v.trim();
      final byTag = raw.startsWith('#');
      // 只去掉一个前导 #（连续 ## 时第二个 '#' 留在搜索词里，行为可预期）。
      final term = (byTag ? raw.substring(1) : raw).trim();
      // 键为空（无搜索词 / 只输入了 '#'）→ 退回默认列表，不发请求。
      final key = term.isEmpty ? '' : (byTag ? '#$term' : term);
      if (key == _appliedQuery) return;
      // 状态在这里一次写齐。原实现 _appliedQuery 在 build 里（_ensureSearchFuture）
      // 才更新，导致"搜 a → 清空 → 再搜 a"被 key 比对短路，输入框有字却停在
      // 默认列表——一个真实存在的 stale-bug，顺手修掉。
      setState(() {
        _appliedQuery = key;
        _search = term;
        _searchByTag = byTag;
        _searchFuture = null;
      });
    });
  }

  /// 懒建当前搜索键对应的合并结果 future（每个键只发一次请求组）。
  /// 在 build 里调用，只写缓存字段，不 setState。
  Future<SearchMergeResult> _ensureSearchFuture() {
    final f = _searchFuture;
    if (f != null) return f;
    final Future<SearchMergeResult> next;
    if (_searchByTag) {
      // tag 单路：**故意不逐项吞错**。线上旧二进制对 by=tag 返回
      // 200+null，F1 已把 null 体抛成 UnexpectedResponseException——
      // 错误必须传到 FutureBuilder 显示"失败/未就绪"，而不是假绿成
      // "没有用户命中该标签"。
      next = _api.searchUsersByTag(_search).then(
        (users) => SearchMergeResult(
          users: users,
          totalRoutes: 1,
          failedRoutes: 0,
        ),
      );
    } else {
      // 普通三路：优先级固定 username > nick > tag（数组顺序即优先级），
      // 单项失败只置空该路，不影响其余路（沿用原两路逐项 catchError 语义）。
      next = runMergedSearch([
        _api.searchUserList('username', _search),
        _api.searchUserList('nick', _search),
        _api.searchUsersByTag(_search),
      ]);
    }
    // 换一个搜索词后 FutureBuilder 会退订，此刻仍在飞的 tag 请求若失败就
    // 变成"无监听者的错误"（zone 里刷 UnhandledException）。ignore() 注册
    // 一个常驻吞错监听，不影响 FutureBuilder 自己收到 snapshot.error。
    next.ignore();
    return _searchFuture = next;
  }

  void _retrySearch() {
    setState(() => _searchFuture = null);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_ownsApi) _api.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final users = await _api.getUserList();
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openDetail(UserMetaData profile) async {
    await Navigator.push(context, PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 300),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, a, __) => UserDetailScreen(profile: profile, proxy: widget.proxy),
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
    // 详情页里可收藏/屏蔽该用户；IndexedStack 保活使本页不会自动重建，
    // 返回后必须刷新，否则红心/屏蔽状态停留在旧值。
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return _buildUserList();
  }

  Widget _buildUserList() {
    return Column(
      children: [
        SearchBarWidget(
          onChanged: _onSearchChanged,
        ),
        Expanded(
          child: _appliedQuery.isNotEmpty ? _buildSearchResults() : _buildDefaultList(),
        ),
      ],
    );
  }

  Widget _buildSearchResults() {
    return FutureBuilder<SearchMergeResult>(
      future: _ensureSearchFuture(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        // 出错态（tag 单路不吞错时可达）：明确说"失败/未就绪"，与真·空结果区分。
        if (snapshot.hasError) {
          return _SearchErrorState(
            error: '${snapshot.error}',
            byTag: _searchByTag,
            onRetry: _retrySearch,
          );
        }
        final outcome = snapshot.data;
        if (outcome == null) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        if (outcome.allRoutesFailed) {
          return _SearchErrorState(
            error: '${outcome.firstError}',
            byTag: false,
            onRetry: _retrySearch,
          );
        }
        final results = outcome.users
            .where((u) => !StorageService.isBlocked(u.username))
            .where((u) => StorageService.matchesGayMode(u.tags))
            .toList();
        return ListView(
          children: [
            // tag 模式隐藏"添加此用户"：它把搜索词当用户名（中文标签还会被
            // _AddUserTile 的 ^[a-zA-Z0-9_]*$ 正则挡掉），对标签查询毫无意义。
            if (!_searchByTag)
              _AddUserTile(username: _search, api: _api, onAdded: _load),
            if (outcome.partialFailure)
              _PartialFailureBanner(
                failed: outcome.failedRoutes,
                total: outcome.totalRoutes,
              ),
            if (results.isEmpty)
              _buildNoResultHint()
            else
              ...results.map((u) => _UserTile(
                key: ValueKey(u.username),
                username: u.username,
                api: _api,
                proxy: widget.proxy,
                onTap: (m) => _openDetail(m),
              )),
            // tag 路命中如实标注服务端截断（LIMIT 15、无游标），不给"加载更多"。
            if (_searchByTag && results.isNotEmpty)
              _TagCapFooter(serverReturned: outcome.users.length),
          ],
        );
      },
    );
  }

  Widget _buildNoResultHint() {
    if (_searchByTag) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 32),
        child: Column(
          children: [
            Icon(Icons.sell_outlined, size: 40, color: Colors.grey),
            SizedBox(height: 8),
            Text('该标签下没有用户命中', style: TextStyle(fontSize: 14)),
            SizedBox(height: 4),
            Text('服务端按标签名精确匹配（权重降序，上限 15）',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 40, color: Colors.grey),
          SizedBox(height: 8),
          Text('没有匹配的用户', style: TextStyle(fontSize: 14)),
          SizedBox(height: 4),
          Text('可点击上方按钮直接添加', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildDefaultList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outlined, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text('加载失败', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SelectableText('$_error', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () { setState(() { _loading = true; _error = null; }); _load(); },
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_users.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.people_outlined, size: 56, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('还没有用户', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('使用上方搜索框搜索用户后添加', style: TextStyle(fontSize: 13, color: Colors.grey)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: const Color(0xFF4F6CFF),
      backgroundColor: Colors.white,
      onRefresh: () async {
        await _load();
      },
      child: ListView.builder(
        itemCount: _users.length + 1,
        itemBuilder: (_, i) {
          if (i == _users.length) {
            if (_users.isEmpty) return const SizedBox.shrink();
            return _LoadMoreButton(
              after: _users.last.username,
              api: _api,
              onLoaded: (newUsers) => setState(() {
                // 去重：tile 用 key: ValueKey(u.username)，服务端返回重叠
                // 用户（after 边界含边界/列表中途变更）会产生重复 Key →
                // "Duplicate keys found" 断言崩溃。
                _users.addAll(
                  newUsers.where(
                    (n) => !_users.any((o) => o.username == n.username),
                  ),
                );
              }),
            );
          }
          final u = _users[i];
          if (StorageService.isBlocked(u.username)) return const SizedBox.shrink();
          if (!StorageService.matchesGayMode(u.tags)) return const SizedBox.shrink();
          return _UserTile(
            key: ValueKey(u.username),
            username: u.username,
            api: _api,
            proxy: widget.proxy,
            onTap: (m) => _openDetail(m),
          );
        },
      ),
    );
  }

}

// ─── 搜索合并层（纯逻辑，独立可测，见 test/search_merge_test.dart）─────────

/// 多路搜索的合并产物：结果列表 + 各路成败情况。
///
/// UI 靠它区分「出错（全部路失败）/ 部分失败（结果可能不完整）/ 真·空结果」
/// 三种形态——尤其不能把"路失败"渲染成"没有结果"。
class SearchMergeResult {
  const SearchMergeResult({
    required this.users,
    required this.totalRoutes,
    required this.failedRoutes,
    this.firstError,
  });

  /// 合并去重后的用户，按路优先级排列（见 [mergeSearchResults]）。
  final List<TwitterUser> users;
  final int totalRoutes;
  final int failedRoutes;

  /// 第一个失败路的异常（按路优先级取最靠前者），用于错误文案。
  final Object? firstError;

  /// 所有路都失败：UI 必须显示错误态，绝不能显示成"没有匹配的用户"。
  bool get allRoutesFailed => totalRoutes > 0 && failedRoutes >= totalRoutes;

  /// 部分路失败：照常显示成功路的结果，但要如实提示可能不完整。
  bool get partialFailure => failedRoutes > 0 && !allRoutesFailed;
}

/// 纯函数：把多路**已完成**的搜索结果按路优先级顺序拼接，并按 username
/// 保序去重（首次出现的位置胜出，同一路内部保持服务端返回顺序）。
///
/// [lists] 的数组顺序即优先级：现状三路为 `[username 命中, nick 命中, tag 命中]`
/// ——username 命中永远排在 nick 命中前（原两路实现的语义，保持不变），
/// tag 命中权重最低垫底（tag 路自身按服务端标签权重降序，不重排）。
List<TwitterUser> mergeSearchResults(List<List<TwitterUser>> lists) {
  final seen = <String>{};
  return [for (final l in lists) ...l]
      // seen.add 返回是否新增，一行完成"保序 + 按 username 去重"。
      .where((u) => seen.add(u.username))
      .toList();
}

class _SettledRoute {
  const _SettledRoute(this.users, this.error);
  final List<TwitterUser> users;
  final Object? error;
}

Future<_SettledRoute> _settleRoute(Future<List<TwitterUser>> route) async {
  try {
    return _SettledRoute(await route, null);
  } catch (e) {
    // 逐项"吞错"：单路失败只把该路置空，不影响其它路——原实现
    // `f.catchError((_) => [])` 的语义，换成 try/catch 是为了同时记录
    // 失败数与异常本身，供 UI 区分三态。
    return _SettledRoute(const <TwitterUser>[], e);
  }
}

/// 并发等待各路搜索 future（逐项吞错），再用 [mergeSearchResults] 合并。
Future<SearchMergeResult> runMergedSearch(
  List<Future<List<TwitterUser>>> routes,
) async {
  final settled = await Future.wait(routes.map(_settleRoute));
  final errors = <Object>[for (final s in settled) if (s.error != null) s.error!];
  return SearchMergeResult(
    users: mergeSearchResults([for (final s in settled) s.users]),
    totalRoutes: routes.length,
    failedRoutes: errors.length,
    firstError: errors.isEmpty ? null : errors.first,
  );
}

// ─── 搜索结果辅助展示组件 ────────────────────────────────────────────────────

/// 搜索出错态：与"真·空结果"严格区分。tag 模式下额外提示
/// "服务端可能尚未支持标签搜索（旧版对 by=tag 返回 200 null）"。
class _SearchErrorState extends StatelessWidget {
  final String error;
  final bool byTag;
  final VoidCallback onRetry;

  const _SearchErrorState({
    required this.error,
    required this.byTag,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(
              byTag ? '标签搜索失败：服务端可能未就绪' : '搜索失败',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            if (byTag)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '（线上旧版对未知 by 会返回 200 空响应，这不代表该标签没有用户）',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ),
            SelectableText(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 部分搜索路失败的提示条：结果照常展示，但如实标注可能不完整。
class _PartialFailureBanner extends StatelessWidget {
  final int failed;
  final int total;

  const _PartialFailureBanner({required this.failed, required this.total});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '部分搜索失败（$failed/$total 路），结果可能不完整',
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),
        ],
      ),
    );
  }
}

/// tag 搜索命中非空时的截断说明：服务端 LIMIT 15、无游标，
/// 所以这里只有说明文字，没有"加载更多"。
class _TagCapFooter extends StatelessWidget {
  /// 服务端（合并去重**前**）返回的条数，用于判断是否触顶。
  final int serverReturned;

  const _TagCapFooter({required this.serverReturned});

  @override
  Widget build(BuildContext context) {
    final truncated = serverReturned >= kTagSearchLimit;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        truncated
            ? '已达服务端返回上限（$kTagSearchLimit 个，按标签权重降序），'
              '其余命中已被截断——该接口无分页'
            : '共 $serverReturned 个命中（服务端按标签权重降序，上限 $kTagSearchLimit）',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
    );
  }
}

class _UserTile extends StatefulWidget {
  final String username;
  final TwitterApi api;
  final ProxyManager proxy;
  final void Function(UserMetaData) onTap;

  const _UserTile({
    super.key,
    required this.username,
    required this.api,
    required this.proxy,
    required this.onTap,
  });

  @override
  State<_UserTile> createState() => _UserTileState();
}

class _UserTileState extends State<_UserTile> {
  UserMetaData? _meta;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_UserTile old) {
    super.didUpdateWidget(old);
    if (old.username != widget.username) {
      _meta = null;
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final meta = await widget.api.getMetaData(widget.username);
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const SizedBox(
              width: 36, height: 36,
              child: _SkeletonCircle(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 14,
                    width: 120,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 10,
                    width: 80,
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final info = _meta?.accountInfo;
    final nick = info?.nick;
    final avatar = info?.avatar;
    final isFav = StorageService.isFav(widget.username);
    return ListTile(
      dense: true,
      leading: ProxyAvatar(
        url: avatar,
        fallbackText: widget.username[0].toUpperCase(),
        proxy: widget.proxy,
        radius: 16,
      ),
      title: Text(
        nick ?? widget.username,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text('@${widget.username}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
      trailing: isFav
          ? const Icon(Icons.favorite, color: Colors.red, size: 18)
          : null,
      onTap: () {
        // _meta 可能加载失败（null）：仍用占位数据进详情页，详情页会自行刷新。
        widget.onTap(_meta ??
            UserMetaData(
              accountInfo: TwitterUser(username: widget.username),
              timeline: const [],
              totalUrls: 0,
            ));
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
                  leading: Icon(
                    isFav ? Icons.favorite : Icons.favorite_border,
                    color: isFav ? Colors.red : Colors.grey,
                  ),
                  title: Text(isFav ? '取消收藏' : '加入收藏'),
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
  }
}

class _AddUserTile extends StatefulWidget {
  final String username;
  final TwitterApi api;
  final VoidCallback? onAdded;

  const _AddUserTile({required this.username, required this.api, this.onAdded});

  @override
  State<_AddUserTile> createState() => _AddUserTileState();
}

class _AddUserTileState extends State<_AddUserTile> {
  bool _isClicked = false;

  @override
  void didUpdateWidget(_AddUserTile old) {
    super.didUpdateWidget(old);
    if (widget.username != old.username) _isClicked = false;
  }

  void _onClick() {
    if (_isClicked) return;
    final regex = RegExp(r'^[a-zA-Z0-9_]*$');
    if (!regex.hasMatch(widget.username)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('不支持的昵称格式，请使用@后面的字符串')),
      );
      return;
    }
    widget.api.createMetaData(widget.username).then((_) {
      if (!mounted) return;
      widget.onAdded?.call();
      setState(() => _isClicked = true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已添加 @${widget.username}')));
    }).catchError((e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('添加失败: $e')));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: Colors.green.withValues(alpha: 0.3)),
        ),
        child: ListTile(
          dense: true,
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: Colors.green.withValues(alpha: 0.1),
            child: Icon(
              _isClicked ? Icons.check : Icons.person_add,
              size: 18,
              color: _isClicked ? Colors.green : Colors.green.shade700,
            ),
          ),
          title: Text(
            _isClicked ? '已添加 @${widget.username}' : '添加 @${widget.username}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: _isClicked ? Colors.green : Colors.green.shade700,
            ),
          ),
          onTap: _isClicked ? null : _onClick,
        ),
      ),
    );
  }
}

class _SkeletonCircle extends StatefulWidget {
  const _SkeletonCircle();
  @override
  State<_SkeletonCircle> createState() => _SkeletonCircleState();
}

class _SkeletonCircleState extends State<_SkeletonCircle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1.0).animate(_ctrl),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.grey,
        ),
      ),
    );
  }
}

class _LoadMoreButton extends StatefulWidget {
  final String after;
  final TwitterApi api;
  final void Function(List<TwitterUser>) onLoaded;

  const _LoadMoreButton({required this.after, required this.api, required this.onLoaded});

  @override
  State<_LoadMoreButton> createState() => _LoadMoreButtonState();
}

class _LoadMoreButtonState extends State<_LoadMoreButton> {
  bool _loading = false;

  Future<void> _loadMore() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final users = await widget.api.getUserList(after: widget.after);
      if (!mounted) return;
      widget.onLoaded(users);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: OutlinedButton.icon(
        onPressed: _loading ? null : _loadMore,
        icon: _loading
            ? const SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.expand_more, size: 16),
        label: _loading ? const Text('加载中...') : const Text('加载更多'),
      ),
    );
  }
}
