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
    // 屏蔽过滤与用户列表页保持一致（纯本地规则，见 StorageService）。
    final visible =
        _users.where((u) => !StorageService.isBlocked(u.username)).toList();
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
          _buildCapFooter(),
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

  /// 如实表达"仅前 15 个 / 已截断"：本接口没有游标，不提供任何加载更多入口。
  Widget _buildCapFooter() {
    final truncated = _users.length >= kTagSearchLimit;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        truncated
            ? '已达服务端返回上限（$kTagSearchLimit 个，按标签权重降序），'
              '其余命中已被截断——该接口无分页'
            : '共 ${_users.length} 个命中（服务端按标签权重降序，上限 $kTagSearchLimit）',
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
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: entries.map((e) {
          final color = e.value > 0
              ? Colors.blue
              : e.value < 0
                  ? Colors.red
                  : Colors.grey;
          final isCurrent = e.key == current;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isCurrent ? color : color.withValues(alpha: 0.2),
                width: isCurrent ? 1.4 : 1,
              ),
            ),
            child: Text(
              '#${e.key}',
              style: TextStyle(fontSize: 11, color: color),
            ),
          );
        }).toList(),
      ),
    );
  }
}
