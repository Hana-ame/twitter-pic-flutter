// Emoji 排行页面：展示各时间段的投票榜单
import 'package:flutter/material.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/storage_service.dart';

class RankingScreen extends StatefulWidget {
  final TwitterApi api;
  final void Function(UserMetaData) onSelectUser;

  const RankingScreen({super.key, required this.api, required this.onSelectUser});

  @override
  State<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends State<RankingScreen> {
  Map<String, EmojiPeriodData>? _data;
  String? _activeEmoji;
  bool _loading = true;
  String? _error;
  String? _loadingUser;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.getRanking();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        final keys = data.keys.toList();
        if (keys.isNotEmpty && (_activeEmoji == null || !data.containsKey(_activeEmoji))) {
          _activeEmoji = keys[0];
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              const Text('排行榜加载失败',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              SelectableText(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_data == null || _data!.isEmpty) {
      return const Center(child: Text('暂无排行数据'));
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Wrap(
              spacing: 8, runSpacing: 8,
              alignment: WrapAlignment.center,
              children: _data!.keys.map((emoji) => GestureDetector(
                onTap: () => setState(() => _activeEmoji = emoji),
                child: Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: _activeEmoji == emoji ? Colors.blue.shade50 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: _activeEmoji == emoji ? Border.all(color: Colors.blue.shade200) : null,
                  ),
                  child: Center(child: Text(emoji, style: const TextStyle(fontSize: 22))),
                ),
              )).toList(),
            ),
            const SizedBox(height: 16),
            if (_activeEmoji != null && _data![_activeEmoji] != null)
              Column(
                children: [
                  _buildList('日榜', _data![_activeEmoji]!.day),
                  _buildList('周榜', _data![_activeEmoji]!.week),
                  _buildList('月榜', _data![_activeEmoji]!.month),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(String title, List<RankingEntry> entries) {
    final visibleEntries = entries
        .where((e) =>
            e.username.isNotEmpty && !StorageService.isBlocked(e.valueUsername))
        .take(10)
        .toList();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          ...visibleEntries.asMap().entries.map((e) {
            final isRowLoading = _loadingUser == e.value.username;
            return ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 12,
                backgroundColor: e.key == 0
                    ? Colors.amber
                    : e.key == 1
                        ? Colors.grey
                        : e.key == 2
                            ? Colors.orange
                            : Colors.grey.shade200,
                child: Text('${e.key + 1}',
                    style: const TextStyle(fontSize: 10, color: Colors.white)),
              ),
              title: Text('@${e.value.username}',
                  style: const TextStyle(fontSize: 14)),
              trailing: isRowLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('${e.value.votes}票',
                      style: const TextStyle(fontSize: 12, color: Colors.blue)),
              onTap: () async {
                if (_loadingUser != null) return;
                final username = e.value.username;
                setState(() => _loadingUser = username);
                try {
                  final profile = await widget.api.getMetaData(username);
                  if (mounted && profile.accountInfo.username.isNotEmpty) {
                    widget.onSelectUser(profile);
                  }
                } catch (_) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('加载用户失败: $username')),
                    );
                  }
                } finally {
                  if (mounted) setState(() => _loadingUser = null);
                }
              },
            );
          }),
        ],
      ),
    );
  }
}

extension on RankingEntry {
  String get valueUsername => username;
}
