// 用户列表页面：显示所有用户并支持搜索、收藏切换
import 'dart:async';

import 'package:flutter/material.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../widgets/proxy_avatar.dart';
import '../widgets/search_bar.dart';
import 'user_detail_screen.dart';

class UserListScreen extends StatefulWidget {
  final ProxyManager proxy;

  const UserListScreen({super.key, required this.proxy});

  @override
  State<UserListScreen> createState() => UserListScreenState();
}

class UserListScreenState extends State<UserListScreen> {
   final TwitterApi _api = TwitterApi();
  List<TwitterUser> _users = [];
  bool _loading = true;
  String? _error;
  String _search = '';
  // 搜索防抖 + 结果 future 复用：原实现每次 build（每个按键）都新建
  // FutureBuilder future，狂发请求且乱序返回会显示错误结果。
  Timer? _debounce;
  String _appliedQuery = '';
  Future<List<TwitterUser>>? _searchFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      final q = v.trim();
      if (q == _appliedQuery) return;
      setState(() => _search = q);
    });
  }

  Future<List<TwitterUser>> _ensureSearchFuture(String q) {
    if (_searchFuture == null || _appliedQuery != q) {
      _appliedQuery = q;
      _searchFuture = Future.wait([
        _api.searchUserList('username', q).catchError((_) => <TwitterUser>[]),
        _api.searchUserList('nick', q).catchError((_) => <TwitterUser>[]),
      ]).then((lists) {
        final seen = <String>{};
        // seen.add 返回是否新增，一行完成去重。
        return [...lists[0], ...lists[1]].where((u) => seen.add(u.username)).toList();
      });
    }
    return _searchFuture!;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _api.dispose();
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

  void _openDetail(UserMetaData profile) {
    Navigator.push(context, PageRouteBuilder(
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
          child: _search.isNotEmpty ? _buildSearchResults() : _buildDefaultList(),
        ),
      ],
    );
  }

  Widget _buildSearchResults() {
    return FutureBuilder<List<TwitterUser>>(
      future: _ensureSearchFuture(_search),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final results = snapshot.data ?? [];
        return ListView(
          children: [
            _AddUserTile(username: _search, api: _api, onAdded: _load),
            if (results.isEmpty)
              const Padding(
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
              )
            else
              ...results
                  .where((u) => !StorageService.isBlocked(u.username))
                  .map((u) => _UserTile(
                    key: ValueKey(u.username),
                    username: u.username,
                    api: _api,
                    proxy: widget.proxy,
                    onTap: (m) => _openDetail(m),
                  )),
          ],
        );
      },
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
              onLoaded: (newUsers) => setState(() => _users.addAll(newUsers)),
            );
          }
          final u = _users[i];
          if (StorageService.isBlocked(u.username)) return const SizedBox.shrink();
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
        if (_meta != null) widget.onTap(_meta!);
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
