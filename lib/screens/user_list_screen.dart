// 用户列表页面：显示所有用户并支持搜索（用户名/昵称/`#标签` 三路）、收藏切换、长按操作与回到顶部
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../widgets/proxy_avatar.dart';
import '../widgets/search_bar.dart';
import '../widgets/tag_selector_modal.dart';
import '../widgets/tag_browse.dart';
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

  final ScrollController _scrollCtrl = ScrollController();
  bool _showBackToTop = false;

  // ─── 按标签过滤 ──────────────────────────────────────────────────────────

  /// 标签云（`GET /api/tag-cloud`，公开接口无鉴权）。为空 = 还没加载或加载失败。
  List<TagCount> _tagCloud = const <TagCount>[];

  /// 当前选中的标签名集合。空集 = 不过滤。
  ///
  /// 选单还是选多：**多选（并集）**。见 [_TagFilterBar] 的注释。
  Set<String> _selectedTags = <String>{};

  /// 选中标签后拉到的**全量**用户（走画廊端点分页），已补齐 tags。
  /// 为空且 [_tagLoading] 为 false 时才回落到本地已加载的 _users 上过滤。
  ///
  /// 多选时是**各标签名册的并集**：每个选中的标签都翻自己的全量，合并去重。
  /// 早先只拉第一个标签的名册，等于把并集当交集算（见 [_toggleTag] 的注释）。
  List<TwitterUser> _tagUsers = const <TwitterUser>[];

  /// **逐标签**的翻页进度：标签名 → 已翻到的 offset 与是否还有下一页。
  ///
  /// 必须按标签分开记：多选下每个标签的名册长度不同、末页时刻不同，只有
  /// 分别记账才能让「加载更多」在并集语义下正确收住（任一还有下一页就继续）。
  final Map<String, _TagPaging> _tagPages = <String, _TagPaging>{};

  /// 本轮加载里**失败**的标签名。空 = 全部成功。
  ///
  /// 部分失败要让 UI 如实区分「这个标签挂了」与「这个标签下没人」——多选时
  /// 一个冷门标签失败不该把已取回的热门结果一起清掉。
  final Set<String> _failedTags = <String>{};

  /// 各标签 `total` 的最大值（即该标签下的**人数**口径）。
  ///
  /// 各标签的 total 不相加（同一账号可同时算进多个标签，加起来会重复计数）。
  /// null = 服务端没给。
  int? _tagMergedTotal;

  /// 画廊端点这一批是否还有下一页（多选下 = 任一选中标签还有下一页）。
  bool _tagHasMore = false;

  bool _tagLoading = false;
  String? _tagError;

  /// 翻页用的单页条数。25 是 `?list=users` 的每页大小，对齐它。
  static const int _kTagPageSize = 25;

  /// 默认列表是否还有下一页（服务端返回空页或无新增去重项时收口）。
  bool _usersHasMore = true;

  void _onStorageChanged() {
    if (!mounted) return;
    setState(() => _refreshVisible());
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final shouldShow = _scrollCtrl.offset > 480;
    if (shouldShow != _showBackToTop && mounted) {
      setState(() => _showBackToTop = shouldShow);
    }
  }

  void _scrollToTop() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? TwitterApi();
    _ownsApi = widget.api == null;
    _scrollCtrl.addListener(_onScroll);
    StorageService.changes.addListener(_onStorageChanged);
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
      _tagError = null;
      _tagPages.clear();
      _tagMergedTotal = null;
    });
    _refreshVisible();
    if (_selectedTags.isNotEmpty) {
      _loadTagUsers();
    }
  }

  void _clearTags() {
    setState(() {
      _selectedTags = <String>{};
      _tagUsers = const <TwitterUser>[];
      _tagHasMore = false;
      _tagError = null;
      _tagPages.clear();
      _tagMergedTotal = null;
      _failedTags.clear();
    });
    _refreshVisible();
  }

  /// 拉选中**所有**标签的第一页（清空重来），合并去重后写入 [_tagUsers]。
  Future<void> _loadTagUsers() async {
    final tags = _selectedTags.toList(growable: false);
    if (tags.isEmpty) return;
    setState(() {
      _tagLoading = true;
      _tagError = null;
      _tagUsers = const <TwitterUser>[];
      _tagPages.clear();
      _tagMergedTotal = null;
      _failedTags.clear();
    });
    final settled = await Future.wait(tags.map((tag) async {
      try {
        final page = await _api.getUsersByTagPage(tag,
            limit: _kTagPageSize, offset: 0);
        final weights = await _api.getTagWeightsBatch(page.usernames);
        final users = <TwitterUser>[];
        for (final name in page.usernames) {
          final w = weights[name];
          if (w == null) continue;
          if ((w[tag] ?? 0) <= 0) continue;
          if (TwitterApi.isKnownMissing(name)) continue;
          users.add(TwitterUser(username: name, tags: w));
        }
        return (
          tag: tag,
          page: page,
          users: users,
          error: null as String?,
        );
      } catch (e) {
        return (
          tag: tag,
          page: null as TagUserPage?,
          users: const <TwitterUser>[],
          error: '$e',
        );
      }
    }));
    if (!mounted) return;
    final failures =
        settled.where((r) => r.error != null).map((r) => r.tag).toList();
    if (failures.length == settled.length) {
      setState(() {
        _tagError = settled.first.error;
        _failedTags
          ..clear()
          ..addAll(failures);
        _tagLoading = false;
      });
      return;
    }
    setState(() {
      _tagPages.clear();
      var mergedTotal = 0;
      var sawTotal = false;
      for (final r in settled) {
        final page = r.page;
        if (page == null) continue;
        final hasMore = !page.isLastPage(_kTagPageSize);
        _tagPages[r.tag] = _TagPaging(
          offset: hasMore ? _kTagPageSize : 0,
          hasMore: hasMore,
        );
        final t = page.total;
        if (t != null) {
          sawTotal = true;
          if (t > mergedTotal) mergedTotal = t;
        }
      }
      _tagMergedTotal = sawTotal ? mergedTotal : null;
      _tagUsers = dedupeByUsername(
        settled.expand((r) => r.users).toList(growable: false),
      );
      _failedTags
        ..clear()
        ..addAll(failures);
      _tagError = failures.isEmpty
          ? null
          : '部分标签加载失败：${failures.join('、')}（其余标签的结果已显示）';
      _tagHasMore = _tagPages.values.any((s) => s.hasMore);
      _tagLoading = false;
    });
    _refreshVisible();
  }

  /// 「加载更多」：**每个**还没到末页的标签各翻一页。
  Future<void> _loadMoreTagUsers() async {
    if (_tagLoading || _selectedTags.isEmpty) return;
    final pending = _selectedTags
        .where((t) => _tagPages[t]?.hasMore ?? true)
        .toList(growable: false);
    if (pending.isEmpty) return;
    setState(() => _tagLoading = true);
    final settled = await Future.wait(pending.map((tag) async {
      final st = _tagPages[tag] ?? const _TagPaging(offset: 0, hasMore: true);
      try {
        final page = await _api.getUsersByTagPage(tag,
            limit: _kTagPageSize, offset: st.offset);
        final weights = await _api.getTagWeightsBatch(page.usernames);
        final users = <TwitterUser>[];
        for (final name in page.usernames) {
          final w = weights[name];
          if (w == null) continue;
          if ((w[tag] ?? 0) <= 0) continue;
          if (TwitterApi.isKnownMissing(name)) continue;
          users.add(TwitterUser(username: name, tags: w));
        }
        return (
          tag: tag,
          page: page,
          users: users,
          error: null as String?,
        );
      } catch (e) {
        return (
          tag: tag,
          page: null as TagUserPage?,
          users: const <TwitterUser>[],
          error: '$e',
        );
      }
    }));
    if (!mounted) return;
    setState(() {
      for (final r in settled) {
        if (r.error != null) {
          _failedTags.add(r.tag);
          continue;
        }
        _failedTags.remove(r.tag);
        final page = r.page;
        if (page == null) continue;
        final st = _tagPages[r.tag] ?? const _TagPaging(offset: 0, hasMore: true);
        final hasMore = !page.isLastPage(_kTagPageSize);
        _tagPages[r.tag] = _TagPaging(
          offset: hasMore ? st.offset + _kTagPageSize : st.offset,
          hasMore: hasMore,
        );
      }
      final failures = pending.where(_failedTags.contains).toList();
      _tagUsers = dedupeByUsername(
        [..._tagUsers, ...settled.expand((r) => r.users)],
      );
      _tagHasMore = _tagPages.values.any((s) => s.hasMore);
      _tagError = failures.isEmpty
          ? null
          : '继续加载失败：${failures.join('、')}（可再次点击重试）';
      _tagLoading = false;
    });
    _refreshVisible();
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      final raw = v.trim();
      final byTag = raw.startsWith('#');
      final term = (byTag ? raw.substring(1) : raw).trim();
      final key = term.isEmpty ? '' : (byTag ? '#$term' : term);
      if (key == _appliedQuery) return;
      setState(() {
        _appliedQuery = key;
        _search = term;
        _searchByTag = byTag;
        _searchFuture = null;
      });
    });
  }

  Future<SearchMergeResult> _ensureSearchFuture() {
    final f = _searchFuture;
    if (f != null) return f;
    final Future<SearchMergeResult> next;
    if (_searchByTag) {
      next = _api.searchUsersByTag(_search).then(
        (users) => SearchMergeResult(
          users: users,
          totalRoutes: 1,
          failedRoutes: 0,
        ),
      );
    } else {
      next = runMergedSearch([
        _api.searchUserList('username', _search),
        _api.searchUserList('nick', _search),
        _api.searchUsersByTag(_search),
      ]);
    }
    next.ignore();
    return _searchFuture = next;
  }

  void _retrySearch() {
    setState(() => _searchFuture = null);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    StorageService.changes.removeListener(_onStorageChanged);
    _debounce?.cancel();
    if (_ownsApi) _api.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final users = await _api.getUserList();
      if (!mounted) return;
      final fresh = dedupeByUsername(users);
      setState(() {
        _users = fresh;
        _usersHasMore = fresh.isNotEmpty;
        _loading = false;
      });
      _refreshVisible();
      unawaited(_prewarmMeta(users));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _appendUsers(List<TwitterUser> newUsers) {
    final added = dedupeByUsername(newUsers, existing: _users);
    _users.addAll(added);
    if (newUsers.isEmpty || added.isEmpty) {
      _usersHasMore = false;
    }
    _refreshVisible();
    if (added.isNotEmpty) {
      unawaited(_prewarmMeta(added));
    }
  }

  Future<void> _openDetail(UserMetaData profile) async {
    await Navigator.push(context, PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 300),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, a, __) => UserDetailScreen(
        profile: profile,
        proxy: widget.proxy,
        tagBrowse: tagBrowseRequest,
        recordHistory: true,
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
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _buildUserList(),
        if (_showBackToTop)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.small(
              heroTag: 'user_list_back_to_top',
              onPressed: _scrollToTop,
              tooltip: '回到顶部',
              child: const Icon(Icons.vertical_align_top),
            ),
          ),
      ],
    );
  }

  Widget _buildUserList() {
    return Column(
      children: [
        SearchBarWidget(
          onChanged: _onSearchChanged,
          tagCloud: _tagCloud,
          onPickTag: _enterTagSearch,
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

  TagBrowseRequest get tagBrowseRequest => enterTagSearch;

  bool enterTagSearch(String tag, {void Function(bool changed)? callback}) {
    final picked = tag.trim().replaceFirst(RegExp(r'^#+'), '').trim();
    if (picked.isEmpty) {
      callback?.call(false);
      return false;
    }
    _enterTagSearch(picked);
    callback?.call(true);
    return true;
  }

  void _enterTagSearch(String tag) {
    final picked = tag.trim().replaceFirst(RegExp(r'^#+'), '').trim();
    if (picked.isEmpty) return;
    setState(() {
      _appliedQuery = '';
      _search = '';
      _searchByTag = false;
      _searchFuture = null;
      _selectedTags = <String>{picked};
      _tagUsers = const <TwitterUser>[];
      _tagError = null;
      _tagPages.clear();
      _tagMergedTotal = null;
      _failedTags.clear();
    });
    _loadTagUsers();
  }

  Widget _buildSearchResults() {
    return FutureBuilder<SearchMergeResult>(
      future: _ensureSearchFuture(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
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
        final results = visibleUsers(
          outcome.users,
          _selectedTags,
          StorageService.shouldHideUser,
        );
        return RefreshIndicator(
          color: const Color(0xFF4F6CFF),
          onRefresh: () async {
            setState(() => _searchFuture = null);
            await _ensureSearchFuture();
          },
          child: ListView(
            controller: _scrollCtrl,
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
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
                user: u,
                api: _api,
                proxy: widget.proxy,
                onTap: (m) => _openDetail(m),
              )),
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
            const Text('加载失败', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
    if (_visibleUsers.isEmpty) {
      return RefreshIndicator(
        color: const Color(0xFF4F6CFF),
        onRefresh: _load,
        child: ListView(
          controller: _scrollCtrl,
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 64),
            const Icon(Icons.visibility_off_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Center(
              child: Text('当前已加载用户均被屏蔽标签或 Gay 模式规则隐藏',
                  style: TextStyle(fontSize: 14)),
            ),
            if (_usersHasMore) ...[
              const SizedBox(height: 12),
              Center(
                child: _LoadMoreButton(
                  after: _users.last.username,
                  api: _api,
                  onLoaded: (newUsers) => setState(() => _appendUsers(newUsers)),
                ),
              ),
            ],
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: const Color(0xFF4F6CFF),
      onRefresh: () async {
        await _load();
      },
      child: ListView.builder(
        controller: _scrollCtrl,
        itemCount: _visibleUsers.length + (_usersHasMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i == _visibleUsers.length) {
            return _LoadMoreButton(
              after: _users.last.username,
              api: _api,
              onLoaded: (newUsers) => setState(() => _appendUsers(newUsers)),
            );
          }
          final u = _visibleUsers[i];
          return _UserTile(
            key: ValueKey(u.username),
            username: u.username,
            user: u,
            api: _api,
            proxy: widget.proxy,
            onTap: (m) => _openDetail(m),
          );
        },
      ),
    );
  }

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
    if (_visibleUsers.isEmpty) {
      return RefreshIndicator(
        color: const Color(0xFF4F6CFF),
        onRefresh: _loadTagUsers,
        child: ListView(
          controller: _scrollCtrl,
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
    return RefreshIndicator(
      color: const Color(0xFF4F6CFF),
      onRefresh: _loadTagUsers,
      child: ListView.builder(
        controller: _scrollCtrl,
        itemCount: _visibleUsers.length + 1 + (_tagError != null ? 1 : 0),
        itemBuilder: (_, i) {
          if (_tagError != null && i == 0) {
            return _PartialTagFailureBanner(
              message: _tagError!,
              failedTags: _failedTags.toList(growable: false),
              onRetry: _loadTagUsers,
            );
          }
          final idx = _tagError != null ? i - 1 : i;
          if (idx == _visibleUsers.length) {
            return _TagLoadMore(
              loading: _tagLoading,
              hasMore: _tagHasMore,
              loadedCount: _tagUsers.length,
              peopleText: _tagMergedTotal == null ? null : '$_tagMergedTotal',
              onMore: _loadMoreTagUsers,
            );
          }
          final u = _visibleUsers[idx];
          return _UserTile(
            key: ValueKey(u.username),
            username: u.username,
            user: u,
            api: _api,
            proxy: widget.proxy,
            onTap: (m) => _openDetail(m),
          );
        },
      ),
    );
  }

  List<TwitterUser> _visibleUsers = const <TwitterUser>[];

  void _refreshVisible() {
    final source = _selectedTags.isNotEmpty && _tagUsers.isNotEmpty
        ? _tagUsers
        : _users;
    final filtered = filterUsersByTags(source, _selectedTags);
    _visibleUsers =
        applyVisibleRules(filtered, StorageService.shouldHideUser);
  }

  static const int _kPrewarmCount = 12;
  static const int _kPrewarmConcurrency = 6;

  Future<void> _prewarmMeta(List<TwitterUser> users) async {
    final names =
        users.take(_kPrewarmCount).map((u) => u.username).toList(growable: false);
    if (names.isEmpty) return;
    for (var i = 0; i < names.length; i += _kPrewarmConcurrency) {
      if (!mounted) return;
      final chunk = names.skip(i).take(_kPrewarmConcurrency);
      await Future.wait(
        chunk.map((n) => _api.getMetaData(n).then((_) {}, onError: (_) {})),
      );
    }
  }
}

/// 纯函数：按 username 保序去重。[existing] 里的用户名也算已出现。
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

class SearchMergeResult {
  const SearchMergeResult({
    required this.users,
    required this.totalRoutes,
    required this.failedRoutes,
    this.firstError,
  });

  final List<TwitterUser> users;
  final int totalRoutes;
  final int failedRoutes;
  final Object? firstError;

  bool get allRoutesFailed => totalRoutes > 0 && failedRoutes >= totalRoutes;
  bool get partialFailure => failedRoutes > 0 && !allRoutesFailed;
}

List<TwitterUser> mergeSearchResults(List<List<TwitterUser>> lists) {
  final seen = <String>{};
  return [for (final l in lists) ...l]
      .where((u) => u.username.isNotEmpty && seen.add(u.username))
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
    return _SettledRoute(const <TwitterUser>[], e);
  }
}

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

const int kTagSearchLimit = 15;

class _TagCapFooter extends StatelessWidget {
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

class _PartialTagFailureBanner extends StatelessWidget {
  final String message;
  final List<String> failedTags;
  final VoidCallback onRetry;

  const _PartialTagFailureBanner({
    super.key,
    required this.message,
    required this.failedTags,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFC978)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFE08600)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  failedTags.isEmpty
                      ? message
                      : '标签「${failedTags.join('、')}」没加载出来，下面是其余标签的结果',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF7A4B00)),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('重试失败标签'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TagPaging {
  final int offset;
  final bool hasMore;

  const _TagPaging({required this.offset, required this.hasMore});
}

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
                    peopleText: '${t.count}',
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

class _TagChip extends StatelessWidget {
  final String tag;
  final String peopleText;
  final bool selected;
  final VoidCallback onTap;

  const _TagChip({
    required this.tag,
    required this.peopleText,
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
            Text(
              peopleText,
              style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TagLoadMore extends StatelessWidget {
  final bool loading;
  final bool hasMore;
  final int loadedCount;
  final String? peopleText;
  final VoidCallback onMore;

  const _TagLoadMore({
    required this.loading,
    required this.hasMore,
    required this.loadedCount,
    required this.onMore,
    this.peopleText,
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
            peopleText == null
                ? '已列出 $loadedCount 人'
                : '已列出 $loadedCount 人（该标签共 $peopleText 人）',
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
  final FutureOr<void> Function(UserMetaData) onTap;
  final TwitterUser? user;

  const _UserTile({
    super.key,
    required this.username,
    required this.api,
    required this.proxy,
    required this.onTap,
    this.user,
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
    _adopt();
  }

  @override
  void didUpdateWidget(_UserTile old) {
    super.didUpdateWidget(old);
    if (old.username != widget.username) _adopt();
  }

  void _adopt() {
    if (_meta != null &&
        _meta!.accountInfo.username == widget.username &&
        (_meta!.accountInfo.avatar != null || _meta!.accountInfo.nick != null)) {
      return;
    }

    final u = widget.user;
    if (u != null && (u.avatar != null || u.nick != null)) {
      _meta = UserMetaData(
        accountInfo: TwitterUser(
          username: u.username,
          nick: u.nick,
          avatar: u.avatar,
          totalUrls: u.totalUrls,
          tags: u.tags,
        ),
        timeline: const [],
        totalUrls: u.totalUrls ?? 0,
      );
      _loading = false;
      return;
    }

    _meta = null;
    _loading = true;
    _load();
  }

  Future<void> _load() async {
    try {
      final meta = await widget.api.getMetaData(widget.username);
      if (!mounted) return;
      final accountInfo = meta.accountInfo;
      final mergedAccountInfo = TwitterUser(
        username: accountInfo.username,
        nick: accountInfo.nick,
        avatar: accountInfo.avatar,
        totalUrls: accountInfo.totalUrls ?? widget.user?.totalUrls,
        tags: (widget.user?.tags.isNotEmpty ?? false)
            ? widget.user!.tags
            : accountInfo.tags,
      );
      setState(() {
        _meta = UserMetaData(
          accountInfo: mergedAccountInfo,
          timeline: meta.timeline,
          totalUrls: meta.totalUrls,
        );
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      final u = widget.user;
      if (u != null && _meta == null) {
        _meta = UserMetaData(
          accountInfo: TwitterUser(
            username: u.username,
            nick: u.nick,
            avatar: u.avatar,
            totalUrls: u.totalUrls,
            tags: u.tags,
          ),
          timeline: const [],
          totalUrls: u.totalUrls ?? 0,
        );
      }
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
        fallbackText: widget.username.isNotEmpty
            ? widget.username[0].toUpperCase()
            : '?',
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
      onTap: () async {
        await widget.onTap(_meta ??
            UserMetaData(
              accountInfo: TwitterUser(username: widget.username),
              timeline: const [],
              totalUrls: 0,
            ));
        if (mounted) unawaited(_load());
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('已屏蔽 @${widget.username}'),
                        action: SnackBarAction(
                          label: '撤销',
                          onPressed: () =>
                              StorageService.removeBlockedUser(widget.username),
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
      _tagPickerEntry?.remove();
      _tagPickerEntry = null;
      _showTagPicker = false;
      _pendingTags = const {};
    }
  }

  @override
  void dispose() {
    _tagPickerEntry?.remove();
    _tagPickerEntry = null;
    super.dispose();
  }

  void _onClick() {
    if (_isClicked || _submitting) return;
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

  Map<String, int> _pendingTags = const {};
  OverlayEntry? _tagPickerEntry;

  void _openTagPicker() {
    if (_tagPickerEntry != null) return;
    _tagPickerEntry = OverlayEntry(
      builder: (overlayContext) => TagSelectorModal(
        isOpen: true,
        requireAtLeastOneTag: true,
        username: widget.username,
        initialValues: _pendingTags,
        onClose: () {
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

  Future<void> _submitWithTags(Map<String, int> tags) async {
    if (tags.isEmpty) return;
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
        decoration: const BoxDecoration(
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
