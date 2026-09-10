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
  late UserMetaData _profile;
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
    _profile = widget.profile;
    _username = _profile.accountInfo.username;
    _loadTags();
    _loadEmojis();
    // 占位数据（元数据加载失败时点进来的）：自动拉取完整数据。
    if (_profile.timeline.isEmpty) {
      _refreshProfile();
    }
  }

  /// 拉取最新元数据。返回 null 表示成功，否则为错误信息（供下拉刷新提示）。
  Future<String?> _refreshProfile() async {
    try {
      final refreshed = await _api.getMetaData(_username, forceRefresh: true);
      if (!mounted) return null;
      setState(() => _profile = refreshed);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  @override
  void didUpdateWidget(UserDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile != widget.profile) {
      _profile = widget.profile;
      // 换用户时必须重置标签/表情/展开状态并重新加载，否则上一个用户
      // 的标签和表情投票会串到新用户页面上。
      final newUsername = widget.profile.accountInfo.username;
      if (newUsername != _username) {
        _username = newUsername;
        _userTags = {};
        _emojiCounts = {};
        _votingEmoji = null;
        _showAll = false;
        _mediaLimit = 10;
        _loadTags();
        _loadEmojis();
      }
    }
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
      // 重新拉取最新元数据
      final refreshed = await _api.getMetaData(_username, t: DateTime.now().toIso8601String(), forceRefresh: true);
      if (mounted) {
        setState(() => _profile = refreshed);
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

  bool _savingTags = false;

  Future<void> _handleConfirmTags(Map<String, int> tags) async {
    if (_savingTags) return;
    setState(() {
      _showTagModal = false;
      _userTags = tags.map((k, v) => MapEntry(k, v as dynamic));
      _savingTags = true;
    });
    try {
      await _api.createMetaData(_username, body: tags, doNotTag: false, doNotRenew: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('标签已保存')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
    } finally {
      if (mounted) setState(() => _savingTags = false);
    }
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

  // 批量下载根目录：Windows 用用户 Downloads，其余平台用应用私有文档目录。
  //
  // Android 不能硬编码 /storage/emulated/0/Download：targetSdk 34 分区存储下
  // 写公共目录需 MANAGE_EXTERNAL_STORAGE 权限，Directory.create() 会抛
  // Permission denied 并被外层 catch 吞成"下载失败"（三个下载模式全挂）。
  // 私有文档目录无需任何权限，下载后可通过分享或"打开目录"访问。
  Future<String> _downloadBaseDir() async {
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
    final items = _profile.timeline;
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
        // am start -d 需要 URI 而非裸路径（裸路径打不开目录且无返回值检查）。
        // Process.run 失败只返回非零 exitCode，不抛异常。
        await Process.run('am', [
          'start', '-a', 'ACTION_VIEW', '-d', 'file://${dlDir.path}',
        ]);
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

  /// 流式写入文件，成功返回 true。
  ///
  /// 连接或写入任一步失败时关闭句柄并删除半写文件——原实现 writeFrom 抛错
  /// （磁盘满/连接中断）时 RAF 不关闭，残留部分写入文件。
  Future<bool> _streamToFile(HttpClient client, Uri uri, File file) async {
    RandomAccessFile? raf;
    var ok = false;
    try {
      final req = await client.getUrl(uri);
      final resp = await req.close();
      if (resp.statusCode != 200) return false;
      final rafHandle = await file.open(mode: FileMode.write);
      raf = rafHandle;
      await for (final chunk in resp) {
        await rafHandle.writeFrom(chunk);
      }
      await rafHandle.close();
      raf = null;
      ok = true;
      return true;
    } catch (_) {
      return false;
    } finally {
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      // 响应流无需单独关闭：外层 client.close() 会释放所有连接，且
      // HttpClientResponse 既无 close() 也无 cancel() 方法。
      if (!ok) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  // 主通道：通过本机 ECH 代理流式下载（HttpClient + EchUrl）。
  Future<void> _downloadAll() => _batchDownload((item, file) async {
        final port = widget.proxy.port;
        if (port == null) return false;
        final echUrl = EchUrl.rewrite(item.url, port);
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 30);
        try {
          return await _streamToFile(client, Uri.parse(echUrl), file);
        } finally {
          client.close();
        }
      });

  // 兼容下载：走代理但不流式（整包读入内存），用于对比。
  Future<void> _downloadAllLegacy() => _batchDownload((item, file) async {
        final port = widget.proxy.port;
        if (port == null) return false;
        final echUrl = EchUrl.rewrite(item.url, port);
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 30);
        try {
          final req = await client.getUrl(Uri.parse(echUrl));
          final res = await req.close();
          if (res.statusCode != 200) return false;
          final bb = BytesBuilder(copy: false);
          await for (final chunk in res) {
            bb.add(chunk);
          }
          final bytes = bb.takeBytes();
          await file.writeAsBytes(bytes);
          return true;
        } catch (_) {
          return false;
        } finally {
          client.close();
        }
      });

  // 应急下载：直接走原始 URL（不经 ECH），仅在代理完全失效时用。
  Future<void> _downloadEmergency() => _batchDownload((item, file) async {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 30);
        try {
          return await _streamToFile(client, Uri.parse(item.url), file);
        } finally {
          client.close();
        }
      });

  @override
  Widget build(BuildContext context) {
    final info = _profile.accountInfo;
    final isFav = StorageService.isFav(_username);
    final isBlocked = StorageService.isBlocked(_username);
    final timeline = _profile.timeline;
    final displayTimeline = _showAll ? timeline : timeline.take(_mediaLimit).toList();
    final hasMore = !_showAll && timeline.length > _mediaLimit;
    // 屏蔽规则生效：用户标签命中“标签管理→屏蔽”列表时给提示条。
    // 标签挂在用户级别（timeline 条目无 tag），故只提示、不自动藏内容。
    final blockedHits =
        StorageService.getBlockTags().where(_userTags.containsKey).toList();
    final showBlockBanner = blockedHits.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text('@$_username'),
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
            color: const Color(0xFF4F6CFF),
            backgroundColor: Colors.white,
            onRefresh: () async {
              // 媒体时间线也要刷新：此前只重载标签/表情，卡在“暂无内容”
              // 时下拉永远救不回来。
              final err = await _refreshProfile();
              await _loadTags();
              await _loadEmojis();
              if (!mounted || err == null) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('内容刷新失败: $err'),
              ));
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
                    padding: EdgeInsets.symmetric(vertical: 48, horizontal: 16),
                    child: Column(
                      children: [
                        Icon(Icons.photo_library_outlined, size: 48, color: Colors.grey),
                        SizedBox(height: 12),
                        Text('暂无内容', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        SizedBox(height: 4),
                        Text('该用户还没有发布任何媒体', style: TextStyle(color: Colors.grey, fontSize: 13)),
                      ],
                    ),
                  );
                }
                if (j < displayTimeline.length) {
                  final item = displayTimeline[j];
                  return _MediaCard(key: ValueKey(item.url), item: item, proxy: widget.proxy);
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: OutlinedButton.icon(
                    onPressed: () => setState(() => _mediaLimit += 10),
                    icon: const Icon(Icons.expand_more, size: 16),
                    label: const Text('加载更多'),
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
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              ProxyAvatar(
                url: info.avatar,
                fallbackText: _username[0].toUpperCase(),
                proxy: widget.proxy,
                radius: 32,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.nick ?? _username,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@$_username',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
            _pill('下载 ${_profile.totalUrls}', Icons.download, Colors.indigo, _downloadAll),
            _pill('兼容下载', Icons.download_done, Colors.teal, _downloadAllLegacy),
            _pill('应急下载', Icons.emergency, Colors.orange, _downloadEmergency),
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
      margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          if (isVideo)
            TwitterVideo(url: item.url, proxy: proxy)
          else
            TwitterImage(url: item.url, proxy: proxy),
          if (item.date != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.schedule, size: 12, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    item.date!,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}