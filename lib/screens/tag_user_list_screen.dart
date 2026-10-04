// 标签用户列表页：展示某个 tag 下命中的用户（by=tag 搜索）。
//
// 外注风格对齐 RankingScreen：`TwitterApi`、`ProxyManager` 与
// "选用户 → 开详情" 回调全部从构造参数进来，不自造全局单例、不持有任何
// 静态状态；页面本身不知道详情页长什么样，push 由调用方在回调里做
// （现状全仓库无命名路由，均为命令式 Navigator.push）。
//
// 契约要点（后端 by=tag）：按标签名**精确匹配**、结果按标签权重降序、
// **LIMIT 15 且没有游标/offset**。所以本页**没有"加载更多"**——
// 结果达到 15 即视为可能被服务端截断，UI 如实标注，不复用
// `list=users` 的 after 游标。
//
// 三态严格区分：加载中 / 出错 / 真·空结果。出错态专门提示"服务端可能
// 未就绪"——线上旧二进制对未知 by 返回 200 + body null，F1 已把 null
// 抛成 UnexpectedResponseException；若把它渲染成空列表就是假绿。

import 'package:flutter/material.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../widgets/proxy_avatar.dart';

/// by=tag 的服务端返回上限（无分页）。
const int kTagSearchLimit = 15;

class TagUserListScreen extends StatefulWidget {
  /// 标签名（传入时不带 `#`；容错：若带前导 # 会被剥掉）。
  final String tag;
  final TwitterApi api;
  final ProxyManager proxy;

  /// 选中用户后回调，参数是已拉好的完整元数据。调用方负责打开
  /// UserDetailScreen（照 main.dart / user_list_screen 的 Navigator.push 写法）。
  final void Function(UserMetaData) onSelectUser;

  const TagUserListScreen({
    super.key,
    required this.tag,
    required this.api,
    required this.proxy,
    required this.onSelectUser,
  });

  @override
  State<TagUserListScreen> createState() => _TagUserListScreenState();
}

class _TagUserListScreenState extends State<TagUserListScreen> {
  List<TwitterUser> _users = [];
  bool _loading = true;
  String? _error;
  /// 正在拉元数据的用户名（tile 点击防重入，同 RankingScreen 的 _loadingUser）。
  String? _loadingUser;

  String get _tag => widget.tag.replaceFirst(RegExp(r'^#+'), '').trim();

  @override
  void initState() {
    super.initState();
    // 注意：initState 里只能走 _fetch（初始值本就是 loading），
    // 同步 setState 会命中 "setState() called during build" 断言。
    _fetch();
  }

  /// 首发请求。状态复位由调用方负责（见 [_reload]）。
  Future<void> _fetch() async {
    try {
      // F1（worker F1）在 twitter_api.dart 新增的方法，签名：
      //   Future<List<TwitterUser>> searchUsersByTag(String tag)
      // 空标签不发请求（API 层同样有早退兜底）。
      final users = _tag.isEmpty ? <TwitterUser>[] : await widget.api.searchUsersByTag(_tag);
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // 出错 ≠ 空结果：保留 _error，渲染错误态而不是"没有用户命中"。
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 用户触发的重新加载（重试按钮 / 下拉刷新）：先复位到加载态再拉。
  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _fetch();
  }

  Future<void> _openUser(String username) async {
    if (_loadingUser != null) return;
    setState(() => _loadingUser = username);
    UserMetaData profile;
    try {
      profile = await widget.api.getMetaData(username);
    } catch (_) {
      // 元数据拉取失败也要能进详情（详情页会自行刷新），与 _UserTile 的
      // 占位构造路径一致。
      if (!mounted) return;
      setState(() => _loadingUser = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载用户失败: $username，打开后重试刷新')),
      );
      profile = UserMetaData(
        accountInfo: TwitterUser(username: username),
        timeline: const [],
        totalUrls: 0,
      );
      widget.onSelectUser(profile);
      return;
    }
    if (!mounted) return;
    setState(() => _loadingUser = null);
    widget.onSelectUser(profile);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sell_outlined, size: 18),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '#$_tag',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              const Text(
                '标签用户加载失败：服务端可能未就绪',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                '（线上旧版对 by=tag 会返回 200 空响应，这不代表该标签没有用户）',
                style: TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              SelectableText(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    // 本地过滤必须与「用户列表页的 tag 搜索」**逐条对齐**（见
    // user_list_screen.dart 的 _buildSearchResults）。
    //
    // 原来这里只有 isBlocked，漏了 matchesGayMode —— 而同一个 by=tag 查询从
    // 两条路进来会给出**不同的用户集合**：搜索框打 #X 时带 Gay 标签的账号被
    // 过滤掉，从详情页点标签 X 进来却原样列出。Gay 模式存在的全部意义就是
    // 「别让我看到那些账号」，而这条正是漏掉它的那条路。
    final visible = _users
        .where((u) => !StorageService.shouldHideUser(u.username, u.tags))
        .toList();
    if (visible.isEmpty) {
      return RefreshIndicator(
        color: const Color(0xFF4F6CFF),
        backgroundColor: Colors.white,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 64),
            const Icon(Icons.people_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Center(child: Text('标签「#$_tag」下没有用户命中',
                style: const TextStyle(fontSize: 14))),
            const SizedBox(height: 4),
            const Center(
              child: Text('按标签名精确匹配，权重降序，上限 $kTagSearchLimit',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: const Color(0xFF4F6CFF),
      backgroundColor: Colors.white,
      onRefresh: _reload,
      child: ListView(
        children: [
          ...visible.map(_buildTile),
          _buildCapFooter(visible.length),
        ],
      ),
    );
  }

  Widget _buildTile(TwitterUser u) {
    return ListTile(
      dense: true,
      leading: ProxyAvatar(
        url: u.avatar,
        fallbackText: u.username.isNotEmpty ? u.username[0].toUpperCase() : '?',
        proxy: widget.proxy,
        radius: 16,
      ),
      title: Text(
        (u.nick != null && u.nick!.isNotEmpty) ? u.nick! : u.username,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('@${u.username}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
          // 命中理由：响应附带的标签权重（by=tag 时通常含被查标签）。
          // TwitterUser.tags 是 F1 新增字段，缺失/类型不符时回退空 Map，
          // 空就不显示。
          if (u.tags.isNotEmpty) _TagChips(tags: u.tags, current: _tag),
        ],
      ),
      trailing: _loadingUser == u.username
          ? const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: () => _openUser(u.username),
    );
  }

  /// 如实表达"服务端返回了几个 / 本地隐藏了几个 / 是否已截断"。
  ///
  /// 三个数必须分开说，混在一起就会自相矛盾：
  ///   - 服务端返回 [_users.length]（判「是否触顶」要用**过滤前**的数，
  ///     否则本地屏蔽掉 3 个就会误判成没触顶）；
  ///   - 本地实际显示 [visibleCount]；
  ///   - 两者之差是本地规则（屏蔽 / Gay 模式）隐藏掉的。
  ///
  /// 原来这里直接印 _users.length，于是「显示了 12 行、写着共 15 个命中」，
  /// 而同一条查询在用户列表页写的是过滤后的数——同一个查询两个数字。
  Widget _buildCapFooter(int visibleCount) {
    final returned = _users.length;
    final truncated = returned >= kTagSearchLimit;
    final hidden = returned - visibleCount;
    final buf = StringBuffer()
      ..write(truncated
          ? '已达服务端返回上限（$kTagSearchLimit 个，按标签权重降序），'
              '其余命中已被截断——该接口无分页'
          : '服务端返回 $returned 个命中（按标签权重降序，上限 $kTagSearchLimit）');
    if (hidden > 0) {
      buf.write('；其中 $hidden 个被本地屏蔽 / Gay 模式规则隐藏');
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        buf.toString(),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
    );
  }
}

/// 命中标签 chip 行：权重 >0 蓝、<0 红、0 灰（配色口径同 TagDisplayArea，
/// 但不 import 那个文件——它归另一条工作流管，这里只做只读展示）。
/// 被查标签加边框强调；其余降序原样展示。
class _TagChips extends StatelessWidget {
  final Map<String, int> tags;
  final String current;

  const _TagChips({required this.tags, required this.current});

  @override
  Widget build(BuildContext context) {
    final entries = tags.entries.toList()
      ..sort((a, b) {
        final byWeight = b.value.compareTo(a.value);
        // 同权重按标签名升序，与服务端"同权重按 username 升序"式稳定序同理，
        // 避免 Map 迭代顺序导致渲染抖动。
        return byWeight != 0 ? byWeight : a.key.compareTo(b.key);
      });
    final isGay = StorageService.isGayMode();
    // 与 TagDisplayArea **同一条负分口径**：score < 0 的标签全局不展示
    // （commit 6ea90cd）。原来这里只按 Gay 词表过滤，于是同一个人、同一个
    // 标签，在详情页是「看不见」、在标签反查列表里却显示成一枚红色 chip——
    // 同一个东西在两个屏幕上含义相反。
    final visibleEntries = entries
        .where((e) => e.value >= 0)
        .where((e) => isGay || !kGayTags.contains(e.key))
        .toList();
    if (visibleEntries.isEmpty) return const SizedBox.shrink();

    // 高亮（标签管理→高亮）在详情页是带星标的；这里也要带，否则用户点进来
    // 之后想找的那个信号凭空消失。getHighlightTags 只有 TagDisplayArea 一个
    // 调用点 —— 规则存着、设置页也在承诺，却到不了这条路上。
    final hits = StorageService.getHighlightTags().toSet();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: visibleEntries.map((e) {
          final color = e.value > 0
              ? Colors.blue
              : e.value < 0
                  ? Colors.red
                  : Colors.grey;
          final isCurrent = e.key == current;
          final isHighlighted = hits.contains(e.key);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: isHighlighted ? 0.18 : 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                // 高亮用琥珀色边框，被查标签用本标签色 —— 两种强调各占一个
                // 维度，才不会「高亮的标签恰好不是搜的那个」时分不清。
                color: isHighlighted
                    ? Colors.amber.shade400
                    : (isCurrent ? color : color.withValues(alpha: 0.2)),
                width: (isCurrent || isHighlighted) ? 1.4 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isHighlighted) ...[
                  Icon(Icons.star, size: 11, color: Colors.amber.shade700),
                  const SizedBox(width: 3),
                ],
                Text(
                  '#${e.key}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: isHighlighted ? FontWeight.w600 : null,
                    color: color,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
