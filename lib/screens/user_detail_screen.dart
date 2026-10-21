// 用户详情页面：展示头像、标签、投票、媒体筛选/排序及批量下载（含中途取消）
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../utils/ech_url.dart';
import '../utils/media_url.dart';
import '../widgets/proxy_avatar.dart';
import '../widgets/progressive_image.dart';
import '../widgets/twitter_image.dart';
import '../widgets/twitter_video.dart';
import '../widgets/tag_display_area.dart';
import '../widgets/tag_selector_modal.dart';
import '../widgets/horizontal_button_row.dart';
import '../widgets/tag_browse.dart';

/// 详情页媒体类型筛选枚举。
enum MediaFilter {
  all,
  photo,
  video,
}

/// 判断单条时间线项是否为视频/动图。
bool isVideoTimelineItem(TimelineItem item) =>
    item.type == 'video' || item.type == 'animated_gif';

/// 纯函数：按媒体类型筛选并根据 [oldestFirst] 决定正序/倒序。
///
/// 独立为顶层纯函数以便单元测试直接验证筛选与排序契约。
List<TimelineItem> filterAndSortTimeline(
  List<TimelineItem> timeline, {
  MediaFilter filter = MediaFilter.all,
  bool oldestFirst = false,
}) {
  Iterable<TimelineItem> filtered;
  switch (filter) {
    case MediaFilter.all:
      filtered = timeline;
      break;
    case MediaFilter.photo:
      filtered = timeline.where((it) => !isVideoTimelineItem(it));
      break;
    case MediaFilter.video:
      filtered = timeline.where(isVideoTimelineItem);
      break;
  }
  final list = filtered.toList(growable: false);
  if (!oldestFirst || list.length <= 1) return list;
  return list.reversed.toList(growable: false);
}

class UserDetailScreen extends StatefulWidget {
  final UserMetaData profile;
  final ProxyManager proxy;

  /// 「留在来源页按标签查找」的请求句柄，由来源页透传。
  ///
  /// **required + 可空**：取值只有两种，调用方**必须**当场写出来，不许「不写」。
  ///
  ///   - 传了句柄（正常路径，从用户列表页点进来）→ 点标签**留在来源页**，
  ///     不再 push 独立的标签页。
  ///   - 显式传 `null` → 背后没有能递回的列表页，如实说明「此页不支持就地切换」。
  final TagBrowseRequest? tagBrowse;

  /// 仅供测试注入（配假 `HttpClientAdapter`）；生产调用点不传。
  final TwitterApi? api;

  /// 是否在打开/刷新该详情页时写入最近浏览历史。
  ///
  /// 默认 `false` 以保证既有组件测试（如 `fav_tag_browse_contract_test`、
  /// `tag_same_page_test`）在假异步时钟下不会触发额外的磁盘写链；
  /// 生产主列表与排行榜入口显式传 `true`。
  final bool recordHistory;

  const UserDetailScreen({
    super.key,
    required this.profile,
    required this.proxy,
    required this.tagBrowse,
    this.api,
    this.recordHistory = false,
  });

  @override
  State<UserDetailScreen> createState() => _UserDetailScreenState();
}

class _UserDetailScreenState extends State<UserDetailScreen> {
  static const _kEmojis = ['😍', '😋', '😱', '🤢', '🐷', '😅', '💩'];

  /// 生产走默认实例；测试注入假适配器（此前没有注入点，导致本页的标签/
  /// 表情永远打真实网络，widget 测试根本没法构造出标签区）。
  late final TwitterApi _api;

  /// [_api] 是否由本页创建。注入进来的实例归调用方所有——本页替它 dispose
  /// 会让调用方（测试里的 setUp/tearDown、或复用同一实例的别处）拿到一个
  /// 已释放的对象。
  late final bool _ownsApi;
  late UserMetaData _profile;
  bool _showAll = false;
  int _mediaLimit = 10;
  MediaFilter _mediaFilter = MediaFilter.all;
  bool _oldestFirst = false;
  Map<String, dynamic> _userTags = {};
  Map<String, int> _emojiCounts = {};
  String? _votingEmoji;
  bool _showTagModal = false;
  late String _username;

  final ScrollController _scrollCtrl = ScrollController();
  bool _showBackToTop = false;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? TwitterApi();
    _ownsApi = widget.api == null;
    _profile = widget.profile;
    _username = _profile.accountInfo.username;
    _scrollCtrl.addListener(_onScroll);
    if (widget.recordHistory && _username.isNotEmpty) {
      StorageService.addBrowseHistory(
        _username,
        nick: _profile.accountInfo.nick,
        avatar: _profile.accountInfo.avatar,
      );
    }
    _loadTags();
    _loadEmojis();
    // 占位数据（元数据加载失败时点进来的）：自动拉取完整数据。
    if (_profile.timeline.isEmpty) {
      _refreshProfile();
    }
    // 首屏图片提前预热（缩略图变体，很便宜），避免刚进来就是一片白。
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheAhead(0, 6));
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final shouldShow = _scrollCtrl.offset > 480;
    if (shouldShow != _showBackToTop && mounted) {
      setState(() => _showBackToTop = shouldShow);
    }
  }

  void _scrollToTop() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  /// 拉取最新元数据。返回 null 表示成功，否则为错误信息（供下拉刷新提示）。
  Future<String?> _refreshProfile() async {
    try {
      final refreshed = await _api.getMetaData(_username, forceRefresh: true);
      if (!mounted) return null;
      setState(() => _profile = refreshed);
      if (widget.recordHistory && _username.isNotEmpty) {
        StorageService.addBrowseHistory(
          _username,
          nick: refreshed.accountInfo.nick,
          avatar: refreshed.accountInfo.avatar,
        );
      }
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
        _mediaFilter = MediaFilter.all;
        _oldestFirst = false;
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
      // 「更新数据」= 只重抓元数据、**不动标签**：走 do_not_tag 分支。
      // 这一分支与标签无关，所以 tags 传空——但服务端要求该用户已存在
      // （否则 403）。
      await _api.createMetaData(_username, tags: const {}, doNotTag: true);
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
    // **记住旧值以便回滚。**
    final prevTags = _userTags;
    setState(() {
      _showTagModal = false;
      _userTags = tags.map((k, v) => MapEntry(k, v as dynamic));
      _savingTags = true;
    });
    try {
      await _api.createMetaData(_username, tags: tags, doNotTag: false, doNotRenew: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('标签已保存')));
      }
    } catch (e) {
      if (!mounted) return;
      // 回滚到保存前的标签，别让页面停在一个服务端并不认的状态。
      setState(() => _userTags = prevTags);
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

  Future<void> _copyUserInfo() async {
    await Clipboard.setData(ClipboardData(text: '@$_username'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制 @$_username'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  bool _downloading = false;
  bool _cancelDownloadRequested = false;
  // 批量下载进度（header 转圈按钮处显示 x/y），三个下载入口共用。
  int _dlDone = 0;
  int _dlTotal = 0;

  // 批量下载根目录：**用户可见的公共 Download 目录**（浏览器保存图片的位置）。
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

  /// 当前筛选与排序后的时间线。
  List<TimelineItem> get _filteredTimeline => filterAndSortTimeline(
        _profile.timeline,
        filter: _mediaFilter,
        oldestFirst: _oldestFirst,
      );

  /// 三种批量下载的公共骨架：进度统计、目录准备、逐项执行（单项失败
  /// 不中断其余项）、支持中途取消、完成后打开目录并提示结果。差异只在 [fetchOne]。
  Future<void> _batchDownload(
    Future<bool> Function(TimelineItem item, File file) fetchOne,
  ) async {
    if (_downloading) return;
    final items = _filteredTimeline;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('没有可下载的内容'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    setState(() {
      _downloading = true;
      _cancelDownloadRequested = false;
      _dlDone = 0;
      _dlTotal = items.length;
    });

    try {
      final dlDir = Directory('${await _downloadBaseDir()}/$_username');
      try {
        if (!await dlDir.exists()) await dlDir.create(recursive: true);
      } on FileSystemException catch (e) {
        final msg = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
        if (msg.contains('permission') || msg.contains('eacces')) {
          _showPermissionDenied(dir: dlDir.path);
          return;
        }
        rethrow;
      }

      var ok = 0;
      var cancelled = false;
      for (var i = 0; i < items.length; i++) {
        if (!mounted) return;
        if (_cancelDownloadRequested) {
          cancelled = true;
          break;
        }
        final item = items[i];
        try {
          final ext = isVideoTimelineItem(item) ? '.mp4' : '.jpg';
          final base = item.url.split('/').last.split('?').first.split('.').first;
          final file = File('${dlDir.path}/${_username}_$base$ext');
          if (await fetchOne(item, file)) ok++;
        } catch (_) {
          // 单个失败继续下一个
        }
        if (mounted) setState(() => _dlDone = i + 1);
      }

      if (!mounted) return;
      if (ok > 0) {
        if (Platform.isAndroid) {
          await Process.run('am', [
            'start', '-a', 'ACTION_VIEW', '-d', dlDir.path,
          ]);
        } else if (Platform.isWindows) {
          await Process.run('explorer', [dlDir.path]);
        }
      }

      final String msg;
      final Color bg;
      if (cancelled) {
        msg = '已取消下载：已完成 $ok/${items.length} 个\n保存位置：${dlDir.path}';
        bg = Colors.orange.shade800;
      } else if (ok == 0) {
        msg = '下载失败（0/${items.length}），可能是代理或网络问题';
        bg = Colors.red;
      } else {
        msg = '下载完成：成功 $ok/${items.length} 个\n保存位置：${dlDir.path}';
        bg = Colors.green;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: bg,
        duration: ok == 0 ? const Duration(seconds: 4) : const Duration(seconds: 6),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('下载失败: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
          _cancelDownloadRequested = false;
        });
      }
    }
  }

  /// 写公共 Download 目录缺权限时弹出的提示框。
  void _showPermissionDenied({required String dir}) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要"全部文件访问"权限'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '下载保存到公共 Download 目录需要该权限。\n\n'
                '授权方式：\n'
                '  1. 点"去设置"\n'
                '  2. 在打开的页面里找"推图"\n'
                '  3. 打开"允许管理所有文件"开关\n'
                '  4. 返回本 App 重试下载',
              ),
              const SizedBox(height: 8),
              Text(
                '保存位置：\n$dir',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openStorageSettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  Future<void> _openStorageSettings() async {
    await Process.run('am', [
      'start',
      '-a', 'android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION',
    ]);
  }

  /// 流式写入文件，成功返回 true。
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
        if (_cancelDownloadRequested) return false;
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
            if (_cancelDownloadRequested) return false;
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
    final filteredTimeline = _filteredTimeline;
    final displayTimeline = _showAll
        ? filteredTimeline
        : filteredTimeline.take(_mediaLimit).toList();
    // 图片画廊（去重保序）：全屏预览翻页用。视频不进这个列表。
    final imageUrls = <String>[];
    final imageIndex = <String, int>{};
    for (final it in displayTimeline) {
      if (isVideoTimelineItem(it)) continue;
      if (it.url.isEmpty || imageIndex.containsKey(it.url)) continue;
      imageIndex[it.url] = imageUrls.length;
      imageUrls.add(it.url);
    }
    final hasMore = !_showAll && filteredTimeline.length > _mediaLimit;
    // 屏蔽规则生效：用户标签命中「标签管理→屏蔽」列表时给提示条。
    final blockedHits = StorageService.blockTagHits(_userTags);
    final showBlockBanner = blockedHits.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onLongPress: _copyUserInfo,
          child: Text('@$_username'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_outlined, size: 19),
            onPressed: _copyUserInfo,
            tooltip: '复制用户名',
          ),
          IconButton(
            icon: const Icon(Icons.edit, size: 20),
            onPressed: () => setState(() => _showTagModal = true),
            tooltip: '修改标签',
          ),
        ],
      ),
      floatingActionButton: _showBackToTop
          ? FloatingActionButton.small(
              onPressed: _scrollToTop,
              tooltip: '回到顶部',
              child: const Icon(Icons.vertical_align_top),
            )
          : null,
      body: Stack(
        children: [
          RefreshIndicator(
            color: const Color(0xFF4F6CFF),
            onRefresh: () async {
              final err = await _refreshProfile();
              await _loadTags();
              await _loadEmojis();
              if (!mounted || err == null) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('内容刷新失败: $err'),
              ));
            },
            child: ListView.builder(
              controller: _scrollCtrl,
              cacheExtent: 1800,
              padding: const EdgeInsets.all(12),
              itemCount: _detailItemCount(showBlockBanner, displayTimeline, hasMore),
              itemBuilder: (context, i) {
                if (i < _kHeaderCount) return _buildHeader(i, info, isFav, isBlocked);
                var j = i - _kHeaderCount;
                if (showBlockBanner && j == 0) return _buildBlockBanner(blockedHits);
                if (showBlockBanner) j--;
                if (displayTimeline.isEmpty) {
                  return _buildEmptyTimelineState();
                }
                if (j < displayTimeline.length) {
                  final item = displayTimeline[j];
                  return _MediaCard(
                    key: ValueKey('${item.url}#$j'),
                    item: item,
                    proxy: widget.proxy,
                    gallery: imageUrls,
                    galleryIndex: imageIndex[item.url] ?? 0,
                  );
                }
                // 滚到底自动续载下一批：不用手动点"加载更多"，一边滚一边出。
                if (hasMore) _scheduleLoadMore();
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

  Widget _buildEmptyTimelineState() {
    if (_profile.timeline.isNotEmpty && _mediaFilter != MediaFilter.all) {
      final typeLabel = _mediaFilter == MediaFilter.photo ? '图片' : '视频';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
        child: Column(
          children: [
            Icon(
              _mediaFilter == MediaFilter.photo
                  ? Icons.image_not_supported_outlined
                  : Icons.videocam_off_outlined,
              size: 44,
              color: Colors.grey,
            ),
            const SizedBox(height: 10),
            Text(
              '没有$typeLabel内容',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => setState(() {
                _mediaFilter = MediaFilter.all;
                _mediaLimit = 10;
              }),
              icon: const Icon(Icons.filter_alt_off, size: 16),
              label: const Text('查看全部媒体'),
            ),
          ],
        ),
      );
    }
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

  static const int _kHeaderCount = 10; // 头部固定条目数（头像行到媒体筛选栏）

  /// 惰性续载：列表滚到尾部就自动 +10（首屏不满一屏时也会自动补满）。
  /// 用 post-frame 回调，避免在 build 里 setState。
  bool _loadMoreScheduled = false;
  void _scheduleLoadMore() {
    if (_loadMoreScheduled) return;
    _loadMoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMoreScheduled = false;
      if (!mounted) return;
      final before = _mediaLimit;
      final total = _filteredTimeline.length;
      if (_mediaLimit >= total) return;
      setState(() => _mediaLimit = (_mediaLimit + 10).clamp(0, total));
      // 新露出来的这批也提前取一下缩略图。
      _precacheAhead(before, 4);
    });
  }

  /// 预取 [from] 起 [count] 张图片：滑到那里时基本已经在缓存里了。
  void _precacheAhead(int from, int count) {
    if (!mounted) return;
    final port = widget.proxy.port;
    if (port == null) return;
    final timeline = _filteredTimeline;
    var scheduled = 0;
    for (var i = from; i < timeline.length && scheduled < count; i++) {
      final url = timeline[i].url;
      if (!MediaUrl.isImage(url)) continue;
      scheduled++;
      final thumbUrl = MediaUrl.thumbOf(url);
      precacheImage(
        ProgressiveImageProvider(EchUrl.rewrite(thumbUrl, port)),
        context,
      ).catchError((_) {});
    }
  }

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

  // 头部第 i 个条目（0..9）：头像行 / 三排按钮 / 标签区 / 媒体类型筛选与排序栏。
  Widget _buildHeader(int i, TwitterUser info, bool isFav, bool isBlocked) {
    switch (i) {
      case 0:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              ProxyAvatar(
                url: info.avatar,
                fallbackText: _username.isNotEmpty ? _username[0].toUpperCase() : '?',
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
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: _copyUserInfo,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              '@$_username',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.copy, size: 12, color: Colors.grey.shade500),
                        ],
                      ),
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
          _pill(
            _showAll ? '已展开全部' : '展开全部',
            _showAll ? Icons.unfold_less : Icons.expand_more,
            Colors.green,
            () => setState(() {
              _showAll = !_showAll;
              if (!_showAll) _mediaLimit = 10;
            }),
          ),
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
        final dlCount = _mediaFilter == MediaFilter.all
            ? _profile.totalUrls
            : _filteredTimeline.length;
        final dlLabel = _mediaFilter == MediaFilter.all
            ? '下载 $dlCount'
            : (_mediaFilter == MediaFilter.photo
                ? '下载图片 $dlCount'
                : '下载视频 $dlCount');
        return HorizontalButtonRow(buttons: [
          if (_downloading) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '下载中 $_dlDone/$_dlTotal',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
            _pill(
              _cancelDownloadRequested ? '正在取消...' : '取消下载',
              Icons.cancel_outlined,
              Colors.red,
              () {
                if (!_cancelDownloadRequested) {
                  setState(() => _cancelDownloadRequested = true);
                }
              },
            ),
          ] else ...[
            _pill(dlLabel, Icons.download, Colors.indigo, _downloadAll),
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
        return TagDisplayArea(
          tags: _userTags,
          onTapTag: (tag) => _openTagInPlace(tag),
        );
      case 9:
        if (_profile.timeline.isEmpty) return const SizedBox(height: 4);
        return _buildMediaFilterBar();
      default:
        return const SizedBox(height: 4);
    }
  }

  /// 媒体类型筛选（全部 / 图片 / 视频）与时间排序（最新↓ / 最早↑）工具栏。
  Widget _buildMediaFilterBar() {
    final allCount = _profile.timeline.length;
    var videoCount = 0;
    for (final it in _profile.timeline) {
      if (isVideoTimelineItem(it)) videoCount++;
    }
    final photoCount = allCount - videoCount;

    Widget filterChip(MediaFilter type, String label, IconData icon) {
      final selected = _mediaFilter == type;
      final color = selected ? const Color(0xFF4F6CFF) : Colors.grey.shade700;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          if (_mediaFilter == type) return;
          setState(() {
            _mediaFilter = type;
            _mediaLimit = 10;
          });
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _precacheAhead(0, 6));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF4F6CFF).withValues(alpha: 0.14)
                : Colors.grey.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? const Color(0xFF4F6CFF)
                  : Colors.grey.withValues(alpha: 0.3),
              width: selected ? 1.3 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            filterChip(
              MediaFilter.all,
              '全部 ($allCount)',
              Icons.grid_view_rounded,
            ),
            const SizedBox(width: 6),
            filterChip(
              MediaFilter.photo,
              '图片 ($photoCount)',
              Icons.photo_outlined,
            ),
            const SizedBox(width: 6),
            filterChip(
              MediaFilter.video,
              '视频 ($videoCount)',
              Icons.videocam_outlined,
            ),
            const SizedBox(width: 10),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                setState(() {
                  _oldestFirst = !_oldestFirst;
                });
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _precacheAhead(0, 6));
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _oldestFirst
                      ? Colors.teal.withValues(alpha: 0.12)
                      : Colors.grey.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _oldestFirst
                        ? Colors.teal
                        : Colors.grey.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _oldestFirst ? Icons.north : Icons.south,
                      size: 13,
                      color:
                          _oldestFirst ? Colors.teal.shade700 : Colors.grey.shade700,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      _oldestFirst ? '最早优先' : '最新优先',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            _oldestFirst ? FontWeight.w600 : FontWeight.normal,
                        color: _oldestFirst
                            ? Colors.teal.shade700
                            : Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点标签 → **留在用户列表页**按该标签查找，不新开标签页。
  void _openTagInPlace(String tag) {
    final req = widget.tagBrowse;
    if (req == null) {
      _showTagBrowseUnavailable();
      return;
    }
    enterTagInPlace(req, tag, onDone: () {
      if (!mounted) return;
      final nav = Navigator.maybeOf(context);
      if (nav != null && nav.canPop()) nav.pop();
    });
  }

  /// 明确告知「此页不支持就地切标签」，并给出仍然可用的旧路径。
  void _showTagBrowseUnavailable() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('此页不支持标签就地查看，请从用户列表进入'),
        duration: Duration(seconds: 2),
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
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    if (_ownsApi) _api.dispose();
    super.dispose();
  }
}

class _MediaCard extends StatelessWidget {
  final TimelineItem item;
  final ProxyManager proxy;
  final List<String> gallery;
  final int galleryIndex;

  const _MediaCard({
    super.key,
    required this.item,
    required this.proxy,
    required this.gallery,
    required this.galleryIndex,
  });

  @override
  Widget build(BuildContext context) {
    final isVideo = isVideoTimelineItem(item);
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
            TwitterImage(
              url: item.url,
              proxy: proxy,
              thumb: true,
              gallery: gallery,
              galleryIndex: galleryIndex,
            ),
          if (item.date != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    isVideo ? Icons.videocam_outlined : Icons.photo_outlined,
                    size: 12,
                    color: Colors.grey,
                  ),
                  const SizedBox(width: 4),
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
