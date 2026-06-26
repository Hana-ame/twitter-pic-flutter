// 用户列表页面：显示所有用户并支持搜索、收藏切换
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../widgets/fav_list.dart';
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
  bool _showFav = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
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
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => UserDetailScreen(profile: profile, proxy: widget.proxy),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Toggle button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => setState(() => _showFav = !_showFav),
              child: Text(_showFav ? '显示用户列表' : '显示收藏夹'),
            ),
          ),
        ),

        if (_showFav)
          Expanded(child: FavList(api: _api, proxy: widget.proxy))
        else
          Expanded(
            child: _buildUserList(),
          ),
      ],
    );
  }

  Widget _buildUserList() {
    return Column(
      children: [
        SearchBarWidget(
          onChanged: (v) => setState(() => _search = v),
        ),
        Expanded(
          child: _search.isNotEmpty ? _buildSearchResults() : _buildDefaultList(),
        ),
      ],
    );
  }

  Widget _buildSearchResults() {
    return FutureBuilder<List<TwitterUser>>(
      future: Future.wait([
        _api.searchUserList('username', _search),
        _api.searchUserList('nick', _search),
      ]).then((lists) {
        final seen = <String>{};
        return [...lists[0], ...lists[1]].where((u) {
          if (seen.contains(u.username)) return false;
          seen.add(u.username);
          return true;
        }).toList();
      }),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final results = snapshot.data ?? [];
        return ListView(
          children: [
            _AddUserTile(username: _search, api: _api, onAdded: _load),
            ...results.map((u) => _UserTile(
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
            Text('加载失败: $_error', style: const TextStyle(fontSize: 12)),
            ElevatedButton(onPressed: () { setState(() { _loading = true; _error = null; }); _load(); }, child: const Text('重试')),
          ],
        ),
      );
    }
    return ListView.builder(
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
    );
  }

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
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
    final info = _meta?.accountInfo;
    final nick = info?.nick;
    final avatar = info?.avatar;
    return ListTile(
      dense: true,
      leading: ProxyAvatar(
        url: avatar,
        fallbackText: widget.username[0].toUpperCase(),
        proxy: widget.proxy,
        radius: 16,
      ),
      title: Text(
        _loading ? widget.username : (nick ?? widget.username),
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text('@${widget.username}', style: const TextStyle(fontSize: 11)),
      onTap: () {
        if (_meta != null) widget.onTap(_meta!);
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
    return ListTile(
      dense: true,
      leading: const CircleAvatar(radius: 16, child: Icon(Icons.person_add, size: 18)),
      title: Text(_isClicked ? '已添加' : '添加 @${widget.username}', style: const TextStyle(fontSize: 14)),
      onTap: _onClick,
    );
  }
}

class _LoadMoreButton extends StatelessWidget {
  final String after;
  final TwitterApi api;
  final void Function(List<TwitterUser>) onLoaded;

  const _LoadMoreButton({required this.after, required this.api, required this.onLoaded});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: ElevatedButton(
        onPressed: () async {
          try {
            final users = await api.getUserList(after: after);
            onLoaded(users);
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败: $e')));
            }
          }
        },
        child: const Text('加载更多'),
      ),
    );
  }
}
