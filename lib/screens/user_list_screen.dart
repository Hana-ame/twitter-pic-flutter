// 用户列表页面：显示所有用户并支持搜索（用户名/昵称/`#标签` 三路）、收藏切换
import 'dart:async';

import 'package:flutter/material.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../widgets/proxy_avatar.dart';
import '../widgets/search_bar.dart';
import '../widgets/tag_selector_modal.dart';
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

  // ─── 按标签过滤 ──────────────────────────────────────────────────────────

  /// 标签云（`GET /api/tag-cloud`，公开接口无鉴权）。为空 = 还没加载或加载失败。
  List<TagCount> _tagCloud = const <TagCount>[];

  /// 当前选中的标签名集合。空集 = 不过滤。
  ///
  /// 选单还是选多：**多选（并集）**。见 [_TagFilterBar] 的注释。
  Set<String> _selectedTags = <String>{};

  /// 选中标签后拉到的**全量**用户（走画廊端点分页），已补齐 tags。
  /// 为空且 [_tagLoading] 为 false 时才回落到本地已加载的 _users 上过滤。
  List<TwitterUser> _tagUsers = const <TwitterUser>[];

  /// 画廊端点声称的该标签 total（**票数口径**，不是人数）。
  int? _tagTotal;

  /// 画廊端点这一批是否还有下一页。
  bool _tagHasMore = false;

  /// 已经被 offset 翻到第几页（下一页的 offset）。
  int _tagOffset = 0;

  bool _tagLoading = false;
  String? _tagError;

  /// 翻页用的单页条数。25 是 `?list=users` 的每页大小，对齐它。
  static const int _kTagPageSize = 25;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? TwitterApi();
    _ownsApi = widget.api == null;
    _load();
    _loadTagCloud();
  }

  /// 标签云：公开接口、无鉴权，失败不打断用户列表（只让筛选条空着）。
  Future<void> _loadTagCloud() async {
    try {
      final cloud = await _api.getTagCloud(limit: 100);
      if (!mounted) return;
      setState(() => _tagCloud = cloud);
    } catch (_) {
      // 标签云挂了就当没有筛选条，用户列表照常用。不弹错误、不改 _error。
    }
  }

  /// 选中/取消一个标签。
  void _toggleTag(String tag) {
    setState(() {
      if (_selectedTags.contains(tag)) {
        _selectedTags.remove(tag);
      } else {
        _selectedTags.add(tag);
      }
      _tagUsers = const <TwitterUser>[];
      _tagOffset = 0;
      _tagHasMore = false;
      _tagTotal = null;
      _tagError = null;
    });
    _refreshVisible();
    if (_selectedTags.isNotEmpty) {
      // 只拉"选中的第一个标签"的全量：多选是并集，任意一个标签的全量列表
      // 都足以覆盖大部分交集场景，再多拉就是纯流量浪费。
      _loadTagUsers();
    }
  }

  void _clearTags() {
    setState(() {
      _selectedTags = <String>{};
      _tagUsers = const <TwitterUser>[];
      _tagOffset = 0;
      _tagHasMore = false;
      _tagTotal = null;
      _tagError = null;
    });
    _refreshVisible();
  }

  /// 拉选中标签的全量用户（**第一页**，清空重来）。
  ///
  /// 为什么不用 `by=tag`：它硬上限 15 且无游标（[kTagSearchLimit]），拿它
  /// 冒充"这个标签下的全部用户"会静默只显示前 15 个却让人以为看全了。
  /// 画廊端点 `/api/tag/<tag>` 能一直翻到 total（实测 女性 total=7579）。
  Future<void> _loadTagUsers() async {
    final tag = _selectedTags.isEmpty ? '' : _selectedTags.first;
    if (tag.isEmpty) return;
    setState(() {
      _tagLoading = true;
      _tagError = null;
      _tagUsers = const <TwitterUser>[];
      _tagOffset = 0;
    });
    try {
      final page = await _api.getUsersByTagPage(tag,
          limit: _kTagPageSize, offset: 0);
      final hydrated = await _api.hydrateUsernames(page.usernames);
      if (!mounted) return;
      setState(() {
        _tagUsers = hydrated;
        _tagOffset = _kTagPageSize;
        _tagTotal = page.total;
        _tagHasMore = !page.isLastPage(_kTagPageSize);
        _tagLoading = false;
      });
      _refreshVisible();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tagError = e.toString();
        _tagLoading = false;
      });
    }
  }

  /// 「加载更多」：按 offset 翻下一页。
  Future<void> _loadMoreTagUsers() async {
    if (_tagLoading || !_tagHasMore) return;
    final tag = _selectedTags.isEmpty ? '' : _selectedTags.first;
    if (tag.isEmpty) return;
    setState(() => _tagLoading = true);
    try {
      final page = await _api.getUsersByTagPage(tag,
          limit: _kTagPageSize, offset: _tagOffset);
      final hydrated = await _api.hydrateUsernames(page.usernames);
      if (!mounted) return;
      setState(() {
        // 去重：服务端翻页顺序可能变化，同一个用户名可能跨页重复出现。
        final seen = <String>{for (final o in _tagUsers) o.username};
        _tagUsers = [
          ..._tagUsers,
          ...hydrated.where((u) => seen.add(u.username)),
        ];
        _tagOffset += _kTagPageSize;
        _tagTotal = page.total ?? _tagTotal;
        _tagHasMore = !page.isLastPage(_kTagPageSize);
        _tagLoading = false;
      });
      _refreshVisible();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tagError = e.toString();
        _tagLoading = false;
      });
    }
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
      // 首屏本身也可能重叠（服务端塞了新号进列表），同样走去重。
      final fresh = dedupeByUsername(users);
      setState(() {
        _users = fresh;
        _loading = false;
      });
      _refreshVisible();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 搜索态的候选用户：有标签筛选时用全量标签列表，否则用 `_users`。
  List<TwitterUser> get _searchUsers =>
      _selectedTags.isNotEmpty && _tagUsers.isNotEmpty ? _tagUsers : _users;

  /// 把服务端新返回的一页并进 [_users]，**按 username 去重**（保序）。
  ///
  /// ⚠️ 这不是可有可无的保险，是一个真实的线上 bug：分页锚点 `after` 是
  /// **用户名**，而**线上部署的版本是闭区间**——第二页的第一项就是第一页的
  /// 最后一项（实测 2026-10-05：p1.last = NaNa0882，p2.first = NaNa0882）。
  /// 所以每次「加载更多」都必然重复一个用户。仓库里这版代码是按开区间写的，
  /// 本地假数据永远测不出来，只有真机连线上才会现形（撞
  /// `ValueKey(u.username)` 的 "Duplicate keys found" 断言，或列表尾部
  /// 凭空多出一行重复的同名用户）。
  ///
  /// 去重必须同时挡两种重复：
  ///  1. 与已有列表重复 —— 闭区间锚点必然产生的那一个；
  ///  2. **新一页内部自己重复** —— 原实现只查 `_users.any(...)`，
  ///     页面内部的重复会漏过去，同样撞重复 key。
  ///
  /// 把服务端新返回的一页并进 [_users]，**按 username 去重**（保序），并重算
  /// 可见列表。名字为空的用户直接丢（否则空串会挤占 ValueKey）。
  ///
  /// 去重必须同时挡两种重复：
  ///  1. 与已有列表重复 —— 闭区间锚点必然产生的那一个；
  ///  2. **新一页内部自己重复** —— 原实现只查 `_users.any(...)`，
  ///     页面内部的重复会漏过去，同样撞重复 key。
  ///
  /// `seen.add()` 返回"是否新增"，用它一行完成"保序 + 去重"。
  void _appendUsers(List<TwitterUser> newUsers) {
    _users.addAll(dedupeByUsername(newUsers, existing: _users));
    _refreshVisible();
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
        _TagFilterBar(
          cloud: _tagCloud,
          selected: _selectedTags,
          onToggle: _toggleTag,
          onClear: _clearTags,
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
        // 统一走 shouldHideUser（权威判定在 StorageService 里）+ 标签筛选，
// 同样**先算完再渲染**，不再在 ListView 里逐项过滤。
        final results = _searchVisibleUsers;
        // 下拉刷新：**搜索态也必须有**。原来只有默认列表包了
        // RefreshIndicator，搜索结果是一个裸 ListView —— 用户下拉毫无反应，
        // 看起来像卡住了。搜索结果同样会过期（比如刚在详情页改了标签），
        // 没有任何手动刷新入口。
        //
        // 刷新动作是重置 _searchFuture 让同一个键重新发一次请求，而不是
        // 清空搜索词退回默认列表 —— 用户要的是"重看当前这批结果"。
        return RefreshIndicator(
          color: const Color(0xFF4F6CFF),
          backgroundColor: Colors.white,
          onRefresh: () async {
            setState(() => _searchFuture = null);
            await _ensureSearchFuture();
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
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
          ),
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
    if (_selectedTags.isNotEmpty) return _buildTagFilteredList();
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
        itemCount: _visibleUsers.length + 1,
        itemBuilder: (_, i) {
          if (i == _visibleUsers.length) {
            return _LoadMoreButton(
              after: _users.last.username,
              api: _api,
              onLoaded: (newUsers) => setState(_appendUsers),
            );
          }
          final u = _visibleUsers[i];
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

  /// 选中标签后的列表：数据源是画廊端点翻页拉来的**全量** [_tagUsers]，
  /// 末尾是"加载更多标签用户"而不是 `_users` 的 after 游标。
  Widget _buildTagFilteredList() {
    final selected = _selectedTags.join(' / ');
    if (_tagLoading && _tagUsers.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_tagError != null && _tagUsers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text('标签「$selected」加载失败',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SelectableText('$_tagError',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loadTagUsers,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    // 空态：服务端确实没有带这个标签的用户。必须与"出错"分开。
    if (_visibleUsers.isEmpty) {
      return RefreshIndicator(
        color: const Color(0xFF4F6CFF),
        backgroundColor: Colors.white,
        onRefresh: _loadTagUsers,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 64),
            const Icon(Icons.sell_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Center(
              child: Text('标签「$selected」下没有可见用户',
                  style: const TextStyle(fontSize: 14)),
            ),
            const SizedBox(height: 4),
            const Center(
              child: Text('（可能都被屏蔽标签 / Gay 模式规则隐藏了）',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
            const SizedBox(height: 16),
            Center(
              child: OutlinedButton.icon(
                onPressed: _clearTags,
                icon: const Icon(Icons.clear, size: 16),
                label: const Text('清除标签筛选'),
              ),
            ),
          ],
        ),
      );
    }
    final hidden = _tagUsers.length - _visibleUsers.length;
    return RefreshIndicator(
      color: const Color(0xFF4F6CFF),
      backgroundColor: Colors.white,
      onRefresh: _loadTagUsers,
      child: ListView.builder(
        itemCount: _visibleUsers.length + 1,
        itemBuilder: (_, i) {
          if (i == _visibleUsers.length) {
            return _TagLoadMore(
              loading: _tagLoading,
              hasMore: _tagHasMore,
              loadedCount: _tagUsers.length,
              // ⚠️ 绝不说"N 人"：total 是标签云的**票数**，不是能列出的用户数
              // （女性 total=7579，而 by=tag 只能回 15）。措辞刻意含糊成"热度"。
              heatText: _tagTotal == null ? null : '票数 ${_tagTotal}',
              onMore: _loadMoreTagUsers,
            );
          }
          final u = _visibleUsers[i];
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

  /// **已经算好的、该渲染的那一批用户**。绝不在 itemBuilder 里过滤。
  ///
  /// 原来的写法是 `itemCount: _users.length + 1`，然后在 itemBuilder 里
  /// `if (shouldHideUser) return const SizedBox.shrink()` —— 这是错的：
  /// 被屏蔽的行**仍然占着一个 index**，只是渲染成 0×0，于是
  ///  - `itemCount` 与真正可见的行数对不上，滚到底部时提前触发"加载更多"；
  ///  - 屏蔽掉 3 个人，列表尾部就凭空多出 3 段空白（正是 `SizedBox.shrink()`
  ///    留下的坑）；
  ///  - 一旦同一 username 进了 _users（闭区间分页，见 [_appendUsers]），
  ///    重复的 ValueKey 直接触发 "Duplicate keys found" 断言崩溃。
  ///
  /// 现在过滤在 [_refreshVisible] 里一次算完，itemBuilder 只负责渲染。
  List<TwitterUser> _visibleUsers = const <TwitterUser>[];

  /// 标签过滤 + 本地屏蔽/Gay 规则合并后的结果；随搜索态/标签选择变化重算。
  List<TwitterUser> get _searchVisibleUsers => visibleUsers(
        _searchUsers,
        _selectedTags,
        StorageService.shouldHideUser,
      );

  /// _users 的可见切片（默认列表：本地规则 + 标签过滤）。
  ///
  /// 注意 **不**在这里再按标签分页取全量：`?list=users` 每页 25 个、
  /// after 游标只能往前走，用户选了个热门标签时只看已加载的那几十个会造成
  /// "标签下就这么点人"的错觉。选中标签时走 [_loadTagUsers] 那条全量路
  /// （画廊端点翻页到 total），本方法只负责**在已有数据上**过滤。
  void _refreshVisible() {
    // 选中了标签且全量列表已经到手 → 以它为准（_tagUsers 已经过标签过滤，
    // 这里只需再套一层本地隐藏规则；多选并集在 _tagUsers 里已经成立）。
    final source = _selectedTags.isNotEmpty && _tagUsers.isNotEmpty
        ? _tagUsers
        : _users;
    final filtered = filterUsersByTags(source, _selectedTags);
    _visibleUsers =
        applyVisibleRules(filtered, StorageService.shouldHideUser);
  }

}

/// 纯函数：按 username 保序去重。[existing] 里的用户名也算已出现。
///
/// 两处都用它：首屏 [TwitterApi.getUserList] 与「加载更多」的追加（见
/// [_appendUsers]）。
List<TwitterUser> dedupeByUsername(
  List<TwitterUser> users, {
  List<TwitterUser> existing = const <TwitterUser>[],
}) {
  final seen = <String>{for (final o in existing) o.username};
  return [
    for (final u in users)
      if (u.username.isNotEmpty && seen.add(u.username)) u,
  ];
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

/// 标签筛选条：横向滚动的标签 cloud 芯片，点一下选中/取消。
///
/// **多选（并集）而非单选**，理由：标签天然是多维的——"女性"和"二次元"是
/// 正交的两个维度，单选强迫用户在"只要女性"和"只要二次元"之间二选一，而
/// "女性 + 二次元"这个组合恰恰是最常用的一类查询。多选还让"清空即全部"
/// 成为唯一需要的一个操作，交互更少。
class _TagFilterBar extends StatelessWidget {
  final List<TagCount> cloud;
  final Set<String> selected;
  final void Function(String tag) onToggle;
  final VoidCallback onClear;

  const _TagFilterBar({
    required this.cloud,
    required this.selected,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    // 标签云为空 = 接口挂了或还没回来：整条隐藏，不给用户一排空壳。
    if (cloud.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                const Icon(Icons.filter_alt, size: 14, color: Colors.blue),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '已筛选：${selected.join(' / ')}',
                    style: const TextStyle(fontSize: 12, color: Colors.blue),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: onClear,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('清除', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final t in cloud)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _TagChip(
                    tag: t.tag,
                    // 如实标注：Count 是**票数**，不是用户数。
                    heatText: '${t.count}',
                    selected: selected.contains(t.tag),
                    onTap: () => onToggle(t.tag),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单个筛选芯片。样式对齐 TagDisplayArea 的标签 chip（小圆角、淡底、描边）。
class _TagChip extends StatelessWidget {
  final String tag;
  final String heatText;
  final bool selected;
  final VoidCallback onTap;

  const _TagChip({
    required this.tag,
    required this.heatText,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.blue : Colors.grey;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected ? 0.15 : 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? color : color.withValues(alpha: 0.3),
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tag,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : null,
                color: selected ? Colors.blue.shade800 : Colors.grey.shade800,
              ),
            ),
            const SizedBox(width: 4),
            // 票数（热度），不是人数 —— 见 TagCount.count 的注释。
            Text(
              heatText,
              style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标签全量列表尾部的"加载更多" + 如实的截断/热度说明。
class _TagLoadMore extends StatelessWidget {
  final bool loading;
  final bool hasMore;
  final int loadedCount;
  final String? heatText;
  final VoidCallback onMore;

  const _TagLoadMore({
    required this.loading,
    required this.hasMore,
    required this.loadedCount,
    required this.onMore,
    this.heatText,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Column(
        children: [
          if (hasMore)
            OutlinedButton.icon(
              onPressed: loading ? null : onMore,
              icon: loading
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more, size: 16),
              label: Text(loading ? '加载中...' : '加载更多'),
            ),
          const SizedBox(height: 6),
          Text(
            heatText == null
                ? '已列出 $loadedCount 人'
                : '已列出 $loadedCount 人（该标签热度 $heatText，非人数）',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
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
  bool _submitting = false;
  bool _showTagPicker = false;

  @override
  void didUpdateWidget(_AddUserTile old) {
    super.didUpdateWidget(old);
    if (widget.username != old.username) {
      _isClicked = false;
      // 换了搜索词，旧弹层必须收掉，否则 OverlayEntry 泄漏（换 100 次搜索词
      // 就叠 100 层遮罩，点哪儿都点不动）。
      _tagPickerEntry?.remove();
      _tagPickerEntry = null;
      _showTagPicker = false;
      _pendingTags = const {};
    }
  }

  @override
  void dispose() {
    // 弹层挂在根 Overlay 上，不随本 State 卸载而消失：换搜索词 / 离开页面
    // 都必须手动摘掉，否则遮罩会留在屏幕上，点哪儿都没反应。
    _tagPickerEntry?.remove();
    _tagPickerEntry = null;
    super.dispose();
  }

  /// 第一步：校验昵称，然后**先弹标签选择**。
  ///
  /// 以前这一步直接就发请求了（`createMetaData(username)` 不带任何参数），
  /// 而服务端首次添加分支要求必须带标签，所以必然 400——用户看到的是
  /// 「添加失败: HTTP 400: 你没加tag，这是不行的」。现在把这一步前移到
  /// 本地：选完标签再提交，提交一次成功。
  void _onClick() {
    if (_isClicked || _submitting) return;
    // `*` 改成 `+`：`^[a-zA-Z0-9_]*$` 对**空串也匹配**（`*` 允许零次），
    // 于是空用户名能过这道校验，`createMetaData('')` 拼出 `/api/twitter/`
    // 打到 gin 的 NoRoute —— 而 NoRoute 在本项目里回的是 gallery 的 SSR 页面
    // HTTP 200 HTML（go/server/main.go 的 r.NoRoute），
    // 客户端把 200 当成功，于是**一次根本没发生的添加被报成「已添加」**，
    // 还白烧掉服务端 25 次/小时的 POST 配额之一。
    final regex = RegExp(r'^[a-zA-Z0-9_]+$');
    if (!regex.hasMatch(widget.username)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('不支持的昵称格式，请使用@后面的字符串')),
      );
      return;
    }
    setState(() => _showTagPicker = true);
    _openTagPicker();
  }

  /// 提交失败后重新打开标签选择器时带回上次的勾选。
  ///
  /// 原来失败后 `_showTagPicker` 一直是 false，而 `_tagScores` 活在已经
  /// unmount 的 modal State 里 —— 用户重开时 4 个标签全没了，得一个一个重按。
  Map<String, int> _pendingTags = const {};

  /// 标签选择器的 Overlay 句柄。见 [_openTagPicker] 的注释。
  OverlayEntry? _tagPickerEntry;

  /// 把标签选择器挂到**根 Overlay**（整屏），而不是作为本 tile 的子 widget。
  ///
  /// 为什么必须走 Overlay：本 tile 的 build 返回一个 Stack，而这个 Stack 是
  /// `ListView(children: [...])` 的直接子节点 —— ListView 给子节点的是**纵向
  /// 无界**约束，弹层在这个 Stack 里只量得出「ListView 里这一行」的高度。
  /// 后果是遮罩高度 0（不可见）、对话框被裁掉大半，**添加用户的标签选择器
  /// 基本点不动** —— 而这正是 v0.6.3 刚修好的那条流程。
  ///
  /// 同一个 widget 在 user_detail_screen.dart（作为 Scaffold body，即紧约束）
  /// 里是正常的，所以这是**调用点特有**的缺陷：只测 standalone 布局的测试
  /// 永远测不出来。OverlayEntry 由 Navigator/Overlay 给出紧约束，
  /// 与 Scaffold body 同级，彻底摆脱宿主的约束形态。
  void _openTagPicker() {
    if (_tagPickerEntry != null) return;
    _tagPickerEntry = OverlayEntry(
      builder: (overlayContext) => TagSelectorModal(
        isOpen: true,
        requireAtLeastOneTag: true,
        username: widget.username,
        // 失败重开时把上次的勾选带回来（_pendingTags 由 _submitWithTags 填）。
        initialValues: _pendingTags,
        onClose: () {
          // 用户主动关掉＝放弃这次的选择，重开时从空白开始。
          _pendingTags = const {};
          _closeTagPicker();
        },
        onConfirm: _submitWithTags,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_tagPickerEntry!);
  }

  void _closeTagPicker() {
    _tagPickerEntry?.remove();
    _tagPickerEntry = null;
    if (mounted) setState(() => _showTagPicker = false);
  }

  /// 第二步：带着标签提交。
  Future<void> _submitWithTags(Map<String, int> tags) async {
    if (tags.isEmpty) return; // modal 已禁用空提交，这里只是兜底
    // 全负分（每个 chip 连点两下 0→1→-1）时 _tagScores 非空但没有一个正权重，
    // 服务端会照单全收写成 cnt=-1，而反查只数正权重 —— 结果是**建了个搜不到
    // 的空账号**。modal 那道门槛只挡空集，挡不住这个，这里补一道。
    if (!tags.values.any((v) => v > 0)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('至少选一个正分标签：全选负分标签建出来的账号搜不到')));
      return;
    }
    _pendingTags = Map<String, int>.from(tags);
    setState(() {
      _submitting = true;
      _showTagPicker = false;
    });
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在添加...')));
    try {
      await widget.api.createMetaData(widget.username, tags: tags);
      if (!mounted) return;
      _pendingTags = const {};
      widget.onAdded?.call();
      setState(() => _isClicked = true);
      messenger.showSnackBar(
          SnackBar(content: Text('已添加 @${widget.username}')));
    } catch (e) {
      if (!mounted) return;
      // 失败：把选择器**重新弹回来**并带上刚才的勾选，别让用户重按一遍。
      setState(() => _showTagPicker = true);
      _openTagPicker();
      messenger.showSnackBar(SnackBar(content: Text('添加失败: $e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
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
                  _isClicked
                      ? Icons.check
                      : (_submitting ? Icons.hourglass_top : Icons.person_add),
                  size: 18,
                  color: _isClicked ? Colors.green : Colors.green.shade700,
                ),
              ),
              title: Text(
                _isClicked
                    ? '已添加 @${widget.username}'
                    : '添加 @${widget.username}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: _isClicked ? Colors.green : Colors.green.shade700,
                ),
              ),
              subtitle: _isClicked
                  ? null
                  : const Text('需选择标签后才能添加',
                      style: TextStyle(fontSize: 11)),
              onTap: (_isClicked || _submitting) ? null : _onClick,
            ),
          ),
        ),
        // 标签选择器**不在这里渲染** —— 它走 _openTagPicker() 挂到根 Overlay 上。
        // 原因见该方法注释：原来它作为本 Stack 的子节点，而本 Stack 是
        // `ListView(children: [...])` 的直接子节点，ListView 给的是**纵向无界**
        // 约束，弹层只量得出 ListView 里这一行的高度，遮罩与对话框都被压扁。
      ],
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
