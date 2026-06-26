// 用户详情页面：展示头像、标签、投票及媒体内容
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../widgets/proxy_avatar.dart';
import '../widgets/twitter_video.dart';
import '../widgets/tag_display_area.dart';
import '../widgets/tag_selector_modal.dart';

class UserDetailScreen extends StatefulWidget {
  final UserMetaData profile;
  final ProxyManager proxy;

  const UserDetailScreen({super.key, required this.profile, required this.proxy});

  @override
  State<UserDetailScreen> createState() => _UserDetailScreenState();
}

class _UserDetailScreenState extends State<UserDetailScreen> {
  static const _kEmojis = ['😍', '😋', '😱', '🤢', '🐷', '😅', '💩'];

  final TwitterApi _api = TwitterApi();
  bool _showAll = false;
  int _mediaLimit = 10;
  Map<String, dynamic> _userTags = {};
  Map<String, int> _emojiCounts = {};
  String? _votingEmoji;
  bool _showTagModal = false;
  bool _loadingTags = false;
  late String _username;

  @override
  void initState() {
    super.initState();
    _username = widget.profile.accountInfo.username;
    _loadTags();
    _loadEmojis();
  }

  void _loadTags() {
    _api.getTags(_username).then((data) {
      if (!mounted) return;
      setState(() => _userTags = Map<String, dynamic>.from(data['tags'] as Map? ?? {}));
    }).catchError((_) {});
  }

  void _loadEmojis() {
    _api.getEmojis(_username).then((data) {
      if (!mounted) return;
      setState(() {
        _emojiCounts = data.map((k, v) => MapEntry(k, (v as num).toInt()));
      });
    }).catchError((_) {});
  }

  void _handleUpdate() {
    _api.createMetaData(_username).catchError((e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('更新失败: $e')));
      }
    });
  }

  void _handleConfirmTags(Map<String, int> tags) {
    setState(() {
      _showTagModal = false;
      _userTags = tags.map((k, v) => MapEntry(k, v as dynamic));
    });
    _api.createMetaData(_username, body: tags, doNotTag: false, doNotRenew: true)
        .catchError((e) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e'))));
  }

  Future<void> _handleEmojiVote(String emoji) async {
    if (_votingEmoji != null) return;
    setState(() => _votingEmoji = emoji);
    try {
      await _api.voteUpEmoji(_username, emoji);
      if (!mounted) return;
      setState(() {
        _emojiCounts[emoji] = (_emojiCounts[emoji] ?? 0) + 1;
        _votingEmoji = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _votingEmoji = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.profile.accountInfo;
    final isFav = StorageService.isFav(_username);
    final isBlocked = StorageService.isBlocked(_username);
    final timeline = widget.profile.timeline;
    final displayTimeline = _showAll ? timeline : timeline.take(_mediaLimit).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('@${_username}'),
        actions: [
          IconButton(
            icon: Icon(Icons.edit, size: 20),
            onPressed: () => setState(() => _showTagModal = true),
            tooltip: '修改标签',
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Row(
                children: [
                  ProxyAvatar(
                    url: info.avatar,
                    fallbackText: _username[0].toUpperCase(),
                    proxy: widget.proxy,
                    radius: 28,
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.nick ?? _username, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      Text('@$_username', style: TextStyle(color: Colors.grey.shade600)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildButtonRow([
                _btn('展开全部', Icons.expand_more, Colors.green, () => setState(() => _showAll = true)),
                _btn(isFav ? '已收藏' : '收藏', Icons.star, Colors.amber, () { setState(() { StorageService.toggleFav(_username); }); }),
                _btn('更新', Icons.refresh, Colors.blue, _handleUpdate),
                _btn(isBlocked ? '取消屏蔽' : '屏蔽', Icons.block, Colors.red, () { setState(() { StorageService.toggleBlock(_username); }); }),
              ]),
              const SizedBox(height: 8),
              _buildButtonRow([
                _btn('下载 ${widget.profile.totalUrls}', Icons.download, Colors.indigo, () {}),
                _btn('兼容下载', Icons.download_done, Colors.teal, () {}),
                _btn('应急下载', Icons.emergency, Colors.orange, () {}),
              ]),
              const SizedBox(height: 8),
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: _kEmojis.map((emoji) {
                    final isVoting = _votingEmoji == emoji;
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ElevatedButton(
                        onPressed: _votingEmoji != null ? null : () => _handleEmojiVote(emoji),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text('$emoji ${isVoting ? '...' : '${_emojiCounts[emoji] ?? 0}'}'),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 4),
              TagDisplayArea(tags: _userTags),
              const SizedBox(height: 4),
              if (displayTimeline.isEmpty)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('暂无内容')))
              else
                ...displayTimeline.map((item) => _MediaCard(key: ValueKey(item.url), item: item, proxy: widget.proxy)),
              if (!_showAll && timeline.length > _mediaLimit)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: ElevatedButton(
                    onPressed: () => setState(() => _mediaLimit += 10),
                    child: const Text('加载更多'),
                  ),
                ),
            ],
          ),
          if (_showTagModal)
            TagSelectorModal(
              isOpen: true,
              onClose: () => setState(() => _showTagModal = false),
              onConfirm: _handleConfirmTags,
              username: _username,
              initialValues: _userTags,
            ),
        ],
      ),
    );
  }

  Widget _buildButtonRow(List<Widget> buttons) {
    return Row(
      children: buttons.map((b) => Expanded(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: b,
      ))).toList(),
    );
  }

  Widget _btn(String label, IconData icon, Color color, VoidCallback onTap) {
    return SizedBox(
      height: 36,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 11)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withValues(alpha: 0.1),
          foregroundColor: Color.lerp(color, Colors.black, 0.3)!,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }
}

class _MediaCard extends StatefulWidget {
  final TimelineItem item;
  final ProxyManager proxy;

  const _MediaCard({super.key, required this.item, required this.proxy});

  @override
  State<_MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<_MediaCard> {
  Uint8List? _bytes;
  Size? _imageSize;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_MediaCard old) {
    super.didUpdateWidget(old);
    if (old.item.url != widget.item.url) {
      _bytes = null;
      _imageSize = null;
      _error = null;
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.item.url;
    final isVideo = widget.item.type == 'video' || widget.item.type == 'animated_gif';

    if (isVideo) return;

    final cachedSize = ProxyManager.sizeCache[url];
    if (cachedSize != null) _imageSize = cachedSize;

    try {
      final bytes = await widget.proxy.fetchAsync(url);
      if (!mounted) return;
      _bytes = bytes;
      _loading = false;
      if (bytes != null) _decodeSize(bytes, url);
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      _error = e.toString();
      _loading = false;
      setState(() {});
    }
  }

  Future<void> _decodeSize(Uint8List bytes, String url) async {
    final size = await ProxyManager.decodeImageSize(bytes);
    if (size != null) {
      ProxyManager.sizeCache[url] = size;
      if (mounted) setState(() => _imageSize = size);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.item.type == 'video' || widget.item.type == 'animated_gif';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          if (isVideo)
            TwitterVideo(url: widget.item.url, proxy: widget.proxy)
          else
            _buildImage(),
          if (widget.item.date != null)
            Padding(
              padding: const EdgeInsets.all(4),
              child: Text(widget.item.date!, style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ),
        ],
      ),
    );
  }

  Widget _buildImage() {
    double? h;
    if (_imageSize != null && _imageSize!.width > 0) {
      final w = MediaQuery.of(context).size.width;
      h = (w * _imageSize!.height / _imageSize!.width).clamp(100, 400);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        height: h ?? 200,
        color: Colors.grey.shade100,
        child: _buildImageContent(),
      ),
    );
  }

  Widget _buildImageContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null || _bytes == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 32, color: Colors.red),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 8, right: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Colors.red.shade300, fontSize: 10),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                ),
              ),
          ],
        ),
      );
    }
    return Image.memory(_bytes!, fit: BoxFit.contain);
  }
}
