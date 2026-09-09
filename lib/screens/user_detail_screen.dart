// 用户详情页面：展示头像、标签、投票及媒体内容
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../utils/ech_url.dart';
import '../widgets/proxy_avatar.dart';
import '../widgets/twitter_image.dart';
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
  late String _username;

  @override
  void initState() {
    super.initState();
    _username = widget.profile.accountInfo.username;
    _loadTags();
    _loadEmojis();
  }

  Future<void> _loadTags() async {
    await _api.getTags(_username).then((data) {
      if (!mounted) return;
      setState(() => _userTags = Map<String, dynamic>.from(data['tags'] as Map? ?? {}));
    }).catchError((_) {});
  }

  Future<void> _loadEmojis() async {
    await _api.getEmojis(_username).then((data) {
      if (!mounted) return;
      setState(() {
        _emojiCounts = data.map((k, v) => MapEntry(k, (v as num).toInt()));
      });
    }).catchError((_) {});
  }

  bool _updating = false;

  Future<void> _handleUpdate() async {
    if (_updating) return;
    setState(() => _updating = true);
    try {
      await _api.createMetaData(_username);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据已更新')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('更新失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  void _handleConfirmTags(Map<String, int> tags) {
    setState(() {
      _showTagModal = false;
      _userTags = tags.map((k, v) => MapEntry(k, v as dynamic));
    });
    _api.createMetaData(_username, body: tags, doNotTag: false, doNotRenew: true)
        .then((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('标签已保存')));
      }
    }).catchError((e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
    });
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('投票失败: $e')));
    }
  }

  bool _downloading = false;
  // 批量下载进度（header 转圈按钮处显示 x/y），三个下载入口共用。
  int _dlDone = 0;
  int _dlTotal = 0;

  // 批量下载根目录：Android 公共 Download，Windows 用户 Downloads，
  // 其余平台用应用文档目录。
  Future<String> _downloadBaseDir() async {
    if (Platform.isAndroid) return '/storage/emulated/0/Download';
    if (Platform.isWindows) {
      final home =
          Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
      return '$home\\Downloads';
    }
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  /// 三种批量下载的公共骨架：进度统计、目录准备、逐项执行（单项失败
  /// 不中断其余项）、完成后打开目录并提示结果。差异只在 [fetchOne]。
  Future<void> _batchDownload(
    Future<bool> Function(TimelineItem item, File file) fetchOne,
  ) async {
    if (_downloading) return;
    final items = widget.profile.timeline;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('没有可下载的内容'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    setState(() {
      _downloading = true;
      _dlDone = 0;
      _dlTotal = items.length;
    });

    try {
      final dlDir = Directory('${await _downloadBaseDir()}/$_username');
      if (!await dlDir.exists()) await dlDir.create(recursive: true);

      var ok = 0;
      for (var i = 0; i < items.length; i++) {
        if (!mounted) return;
        final item = items[i];
        try {
          final ext =
              item.type == 'video' || item.type == 'animated_gif' ? '.mp4' : '.jpg';
          final base = item.url.split('/').last.split('?').first.split('.').first;
          final file = File('${dlDir.path}/${_username}_$base$ext');
          if (await fetchOne(item, file)) ok++;
        } catch (_) {
          // 单个失败继续下一个
        }
        if (mounted) setState(() => _dlDone = i + 1);
      }

      if (!mounted) return;
      if (Platform.isAndroid) {
        await Process.run('am', ['start', '-a', 'ACTION_VIEW', '-d', dlDir.path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [dlDir.path]);
      }

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('下载完成，成功 $ok/${items.length} 个文件'),
        backgroundColor: Colors.green,
      ));
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

  // ─── 下载策略 ──────────────────────────────────────────────────────────────

  /// 主通道：ECH 代理 + 流式。
  Future<bool> _fetchStreamProxy(TimelineItem item, File file) async {
    final port = widget.proxy.port;
    if (port == null) return false;
    final echUrl = EchUrl.rewrite(item.url, port);
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(echUrl));
      final res = await req.close();
      if (res.statusCode != 200) return false;
      final raf = await file.open(mode: FileMode.write);
      await for (final chunk in res) {
        await raf.writeFrom(chunk);
      }
      await raf.close();
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// 兼容通道：ECH 代理 + 内存。
  Future<bool> _fetchMemoryProxy(TimelineItem item, File file) async {
    final port = widget.proxy.port;
    if (port == null) return false;
    final echUrl = EchUrl.rewrite(item.url, port);
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(echUrl));
      final res = await req.close();
      if (res.statusCode != 200) return false;
      final bb = BytesBuilder(copy: false);
      await res.listen((c) => bb.add(c), onDone: () {});
      final bytes = bb.takeBytes();
      await file.writeAsBytes(bytes);
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// 应急通道：原始 URL 直连（不经 ECH）。
  Future<bool> _fetchDirect(TimelineItem item, File file) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(item.url));
      final res = await req.close();
      if (res.statusCode != 200) return false;
      final raf = await file.open(mode: FileMode.write);
      await for (final chunk in res) {
        await raf.writeFrom(chunk);
      }
      await raf.close();
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// 自动降级下载：主通道 → 兼容 → 应急，逐项尝试直到成功。
  Future<bool> _fetchWithFallback(TimelineItem item, File file) async {
    if (await _fetchStreamProxy(item, file)) return true;
    if (await _fetchMemoryProxy(item, file)) return true;
    return _fetchDirect(item, file);
  }

  // ─── 批量下载入口 ──────────────────────────────────────────────────────────

  /// 默认下载：自动降级（主 → 兼容 → 应急）。
  Future<void> _downloadAll() => _batchDownload(_fetchWithFallback);

  /// 仅主通道（ECH 流式），用于对比测试。
  Future<void> _downloadAllLegacy() => _batchDownload(_fetchStreamProxy);

  /// 仅应急通道（直连），用于代理完全失效时。
  Future<void> _downloadEmergency() => _batchDownload(_fetchDirect);

  @override
  Widget build(BuildContext context) {
    final info = widget.profile.accountInfo;
    final isFav = StorageService.isFav(_username);
    final isBlocked = StorageService.isBlocked(_username);
    final timeline = widget.profile.timeline;
    final displayTimeline = _showAll ? timeline : timeline.take(_mediaLimit).toList();
    final hasMore = !_showAll && timeline.length > _mediaLimit;
    // 屏蔽规则生效：用户标签命中“标签管理→屏蔽”列表时给提示条。
    // 标签挂在用户级别（timeline 条目无 tag），故只提示、不自动藏内容。
    final blockedHits =
        StorageService.getBlockTags().where(_userTags.containsKey).toList();
    final showBlockBanner = blockedHits.isNotEmpty;

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
          // ListView.builder 惰性构建：滚动到哪建到哪。原实现把所有媒体卡
          // 一次性塞进 children，“展开全部”会瞬间创建全部 TwitterVideo、
          // 同时触发所有视频下载；builder 化后视频只在滚入视口时才创建/下载。
          RefreshIndicator(
            onRefresh: () async {
              await _loadTags();
              await _loadEmojis();
            },
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _detailItemCount(showBlockBanner, displayTimeline, hasMore),
              itemBuilder: (context, i) {
                if (i < _kHeaderCount) return _buildHeader(i, info, isFav, isBlocked);
                var j = i - _kHeaderCount;
                if (showBlockBanner && j == 0) return _buildBlockBanner(blockedHits);
                if (showBlockBanner) j--;
                if (displayTimeline.isEmpty) {
                  return const Padding(
                      padding: EdgeInsets.all(32), child: Center(child: Text('暂无内容')));
                }
                if (j < displayTimeline.length) {
                  final item = displayTimeline[j];
                  return _MediaCard(key: ValueKey(item.url), item: item, proxy: widget.proxy);
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: ElevatedButton(
                    onPressed: () => setState(() => _mediaLimit += 10),
                    child: const Text('加载更多'),
                  ),
                );
              },
            ),
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

  static const int _kHeaderCount = 10; // 头部固定条目数（头像行到标签区）

  int _detailItemCount(
      bool showBlockBanner, List<TimelineItem> displayTimeline, bool hasMore) {
    final bodyCount = displayTimeline.isEmpty ? 1 : displayTimeline.length;
    return _kHeaderCount +
        (showBlockBanner ? 1 : 0) +
        bodyCount +
        (hasMore ? 1 : 0);
  }

  // 命中屏蔽标签时的提示条。
  Widget _buildBlockBanner(List<String> hits) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.visibility_off, size: 16, color: Colors.red.shade400),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '该用户命中已屏蔽标签：${hits.join('、')}',
              style: TextStyle(fontSize: 11, color: Colors.red.shade700),
            ),
          ),
        ],
      ),
    );
  }

  // 头部第 i 个条目（0..9）：头像行 / 三排按钮 / 标签区，夹以间距。
  Widget _buildHeader(int i, TwitterUser info, bool isFav, bool isBlocked) {
    switch (i) {
      case 0:
        return Row(
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
        );
      case 1:
        return const SizedBox(height: 12);
      case 2:
        return HorizontalButtonRow(buttons: [
          _pill('展开全部', Icons.expand_more, Colors.green, () => setState(() => _showAll = true)),
          _pill(isFav ? '已收藏' : '收藏', Icons.star, Colors.amber, () { setState(() { StorageService.toggleFav(_username); }); }),
          ActionChip(
            onPressed: _updating ? null : _handleUpdate,
            avatar: _updating
                ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue))
                : const Icon(Icons.refresh, size: 14, color: Colors.blue),
            label: const Text('更新', style: TextStyle(fontSize: 11)),
            backgroundColor: Colors.blue.withValues(alpha: 0.1),
            surfaceTintColor: Colors.transparent,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            side: BorderSide(color: Colors.blue.withValues(alpha: 0.4)),
          ),
          _pill(isBlocked ? '取消屏蔽' : '屏蔽', Icons.block, Colors.red, () { setState(() { StorageService.toggleBlock(_username); }); }),
        ]);
      case 3:
        return const SizedBox(height: 8);
      case 4:
        return HorizontalButtonRow(buttons: [
          if (_downloading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(width: 14, height: 14, child: const CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 6),
                  Text(
                    '下载中 $_dlDone/$_dlTotal',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                  ),
                ],
              ),
            )
          else ...[
            _pill('下载 ${widget.profile.totalUrls}', Icons.download, Colors.indigo, _downloadAll),
            _pill('仅主通道', Icons.download_done, Colors.teal, _downloadAllLegacy),
            _pill('仅应急', Icons.emergency, Colors.orange, _downloadEmergency),
          ],
        ]);
      case 5:
        return const SizedBox(height: 8);
      case 6:
        return HorizontalButtonRow(
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
        );
      case 7:
        return const SizedBox(height: 4);
      case 8:
        return TagDisplayArea(tags: _userTags);
      default:
        return const SizedBox(height: 4);
    }
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

class _MediaCard extends StatelessWidget {
  final TimelineItem item;
  final ProxyManager proxy;

  const _MediaCard({super.key, required this.item, required this.proxy});

  @override
  Widget build(BuildContext context) {
    final isVideo = item.type == 'video' || item.type == 'animated_gif';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          // 图片复用 TwitterImage（尺寸缓存/按显示尺寸解码/错误重试展示），
          // 去掉原先复制的一份几乎相同的加载逻辑。
          if (isVideo)
            TwitterVideo(url: item.url, proxy: proxy)
          else
            TwitterImage(url: item.url, proxy: proxy),
          if (item.date != null)
            Padding(
              padding: const EdgeInsets.all(4),
              child: Text(item.date!, style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ),
        ],
      ),
    );
  }
}