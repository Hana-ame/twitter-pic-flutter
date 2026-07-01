// 用户详情页面：展示头像、标签、投票及媒体内容
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../widgets/proxy_avatar.dart';
import '../widgets/twitter_video.dart';
import '../widgets/tag_display_area.dart';
import '../widgets/tag_selector_modal.dart';
import '../widgets/horizontal_button_row.dart';

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

  bool _downloading = false;
  Future<void> _downloadAll() async {
    if (_downloading) return;
    final items = widget.profile.timeline;
    if (items.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('没有可下载的内容'),
          backgroundColor: Colors.red,
        ));
      }
      return;
    }

    setState(() => _downloading = true);

    try {
      String baseDir;
      if (Platform.isAndroid) {
        baseDir = '/storage/emulated/0/Download';
      } else if (Platform.isWindows) {
        final home =
            Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
        baseDir = '$home\\Downloads';
      } else {
        final dir = await getApplicationDocumentsDirectory();
        baseDir = dir.path;
      }

      final dlDir = Directory('$baseDir/$_username');
      if (!await dlDir.exists()) await dlDir.create(recursive: true);

      final urls = items.map((e) => e.url).toList();
      final types = items.map((e) => e.type).toList();

      final allBytes = await Isolate.run<List<Uint8List?>>(() async {
        final proxy = ProxyManager();
        await proxy.load();
        return urls.map((u) {
          try {
            return proxy.fetch(u);
          } catch (_) {
            return null;
          }
        }).toList();
      });

      var ok = 0;
      for (var i = 0; i < items.length; i++) {
        if (!mounted) return;
        final bytes = allBytes[i];
        if (bytes != null) {
          final ext =
              types[i] == 'video' || types[i] == 'animated_gif' ? '.mp4' : '.jpg';
          final base =
              urls[i].split('/').last.split('?').first.split('.').first;
          final file = File('${dlDir.path}/${_username}_$base$ext');
          await file.writeAsBytes(bytes);
          ok++;
        }
      }

      if (!mounted) return;
      if (Platform.isAndroid) {
        await Process.run('am', ['start', '-a', 'ACTION_VIEW', '-d', dlDir.path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [dlDir.path]);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('下载完成，成功 $ok/${items.length} 个文件'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('下载失败: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  // fallback: per-item Isolate.run (keeps UI responsive)
  Future<void> _downloadAllLegacy() async {
    if (_downloading) return;
    final items = widget.profile.timeline;
    if (items.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('没有可下载的内容'),
          backgroundColor: Colors.red,
        ));
      }
      return;
    }
    setState(() => _downloading = true);
    try {
      String baseDir;
      if (Platform.isAndroid) {
        baseDir = '/storage/emulated/0/Download';
      } else if (Platform.isWindows) {
        final home =
            Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
        baseDir = '$home\\Downloads';
      } else {
        final dir = await getApplicationDocumentsDirectory();
        baseDir = dir.path;
      }
      final dlDir = Directory('$baseDir/$_username');
      if (!await dlDir.exists()) await dlDir.create(recursive: true);

      var ok = 0;
      for (var i = 0; i < items.length; i++) {
        if (!mounted) return;
        try {
          final bytes = await widget.proxy.fetchAsync(items[i].url);
          if (bytes != null) {
            final ext = items[i].type == 'video' || items[i].type == 'animated_gif'
                ? '.mp4'
                : '.jpg';
            final base =
                items[i].url.split('/').last.split('?').first.split('.').first;
            final file = File('${dlDir.path}/${_username}_$base$ext');
            await file.writeAsBytes(bytes);
            ok++;
          }
        } catch (_) {}
      }

      if (!mounted) return;
      if (Platform.isAndroid) {
        await Process.run('am', ['start', '-a', 'ACTION_VIEW', '-d', dlDir.path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [dlDir.path]);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('下载完成，成功 $ok/${items.length} 个文件'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('下载失败: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  // emergency: use widget.proxy.fetch directly (sync, freezes UI briefly per item)
  Future<void> _downloadEmergency() async {
    if (_downloading) return;
    final items = widget.profile.timeline;
    if (items.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('没有可下载的内容'),
          backgroundColor: Colors.red,
        ));
      }
      return;
    }
    setState(() => _downloading = true);
    try {
      String baseDir;
      if (Platform.isAndroid) {
        baseDir = '/storage/emulated/0/Download';
      } else if (Platform.isWindows) {
        final home =
            Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
        baseDir = '$home\\Downloads';
      } else {
        final dir = await getApplicationDocumentsDirectory();
        baseDir = dir.path;
      }
      final dlDir = Directory('$baseDir/$_username');
      if (!await dlDir.exists()) await dlDir.create(recursive: true);

      var ok = 0;
      for (final item in items) {
        if (!mounted) return;
        try {
          final bytes = widget.proxy.fetch(item.url);
          if (bytes != null) {
            final ext =
                item.type == 'video' || item.type == 'animated_gif' ? '.mp4' : '.jpg';
            final base =
                item.url.split('/').last.split('?').first.split('.').first;
            final file = File('${dlDir.path}/${_username}_$base$ext');
            await file.writeAsBytes(bytes);
            ok++;
          }
        } catch (_) {}
        // yield to event loop for UI updates
        await Future.delayed(Duration.zero);
      }

      if (!mounted) return;
      if (Platform.isAndroid) {
        await Process.run('am', ['start', '-a', 'ACTION_VIEW', '-d', dlDir.path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [dlDir.path]);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('下载完成，成功 $ok/${items.length} 个文件'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('下载失败: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
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
              HorizontalButtonRow(buttons: [
                _pill('展开全部', Icons.expand_more, Colors.green, () => setState(() => _showAll = true)),
                _pill(isFav ? '已收藏' : '收藏', Icons.star, Colors.amber, () { setState(() { StorageService.toggleFav(_username); }); }),
                _pill('更新', Icons.refresh, Colors.blue, _handleUpdate),
                _pill(isBlocked ? '取消屏蔽' : '屏蔽', Icons.block, Colors.red, () { setState(() { StorageService.toggleBlock(_username); }); }),
              ]),
              const SizedBox(height: 8),
              HorizontalButtonRow(buttons: [
                if (_downloading)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(width: 14, height: 14, child: const CircularProgressIndicator(strokeWidth: 2)),
                      ],
                    ),
                  )
                else ...[
                  _pill('下载 ${widget.profile.totalUrls}', Icons.download, Colors.indigo, _downloadAll),
                  _pill('兼容下载', Icons.download_done, Colors.teal, _downloadAllLegacy),
                  _pill('应急下载', Icons.emergency, Colors.orange, _downloadEmergency),
                ],
              ]),
              const SizedBox(height: 8),
              HorizontalButtonRow(
                height: 32,
                spacing: 4,
                buttons: _kEmojis.map((emoji) {
                  final isVoting = _votingEmoji == emoji;
                  return ActionChip(
                    onPressed: _votingEmoji != null ? null : () => _handleEmojiVote(emoji),
                    avatar: Text(emoji, style: const TextStyle(fontSize: 13)),
                    label: Text(isVoting ? '...' : '${_emojiCounts[emoji] ?? 0}', style: const TextStyle(fontSize: 10)),
                    surfaceTintColor: Colors.transparent,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  );
                }).toList(),
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

  Widget _pill(String label, IconData icon, Color color, VoidCallback onTap) {
    return ActionChip(
      onPressed: onTap,
      avatar: Icon(icon, size: 14, color: color),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      backgroundColor: color.withValues(alpha: 0.1),
      surfaceTintColor: Colors.transparent,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: BorderSide(color: color.withValues(alpha: 0.4)),
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
