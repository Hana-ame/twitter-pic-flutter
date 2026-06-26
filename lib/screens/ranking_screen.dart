// Emoji 排行页面：展示各时间段的投票榜单
import 'package:flutter/material.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.getRanking();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        final keys = data.keys.toList();
        if (keys.isNotEmpty) _activeEmoji = keys[0];
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_data == null || _data!.isEmpty) {
      return const Center(child: Text('暂无排行数据'));
    }

    return Column(
      children: [
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
          Expanded(
            child: ListView(
              children: [
                _buildList('日榜', _data![_activeEmoji]!.day),
                _buildList('周榜', _data![_activeEmoji]!.week),
                _buildList('月榜', _data![_activeEmoji]!.month),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildList(String title, List<RankingEntry> entries) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          ...entries.take(10).toList().asMap().entries.map((e) => ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 12,
              backgroundColor: e.key == 0 ? Colors.amber : e.key == 1 ? Colors.grey : e.key == 2 ? Colors.orange : Colors.grey.shade200,
              child: Text('${e.key + 1}', style: const TextStyle(fontSize: 10, color: Colors.white)),
            ),
            title: Text('@${e.value.username}', style: const TextStyle(fontSize: 14)),
            trailing: Text('${e.value.votes}票', style: const TextStyle(fontSize: 12, color: Colors.blue)),
            onTap: () {
              widget.api.getMetaData(e.value.username).then((profile) {
                if (profile.accountInfo.username.isNotEmpty) {
                  widget.onSelectUser(profile);
                }
              });
            },
          )),
        ],
      ),
    );
  }
}
