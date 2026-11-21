// user_list_widgets.dart
// 从 UserListScreen 拆出的独立 UI 子组件（搜索错误态、部分失败提示、标签筛选条、
// 骨架屏与分页加载按钮），降低单文件复杂度。

import 'package:flutter/material.dart';

import '../api/twitter_api.dart';
import '../models/user.dart';

class SearchErrorState extends StatelessWidget {
  final String error;
  final bool byTag;
  final VoidCallback onRetry;

  const SearchErrorState({
    required this.error,
    required this.byTag,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(
              byTag ? '标签搜索失败：服务端可能未就绪' : '搜索失败',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            if (byTag)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '（线上旧版对未知 by 会返回 200 空响应，这不代表该标签没有用户）',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ),
            SelectableText(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 部分搜索路失败的提示条：结果照常展示，但如实标注可能不完整。
class PartialFailureBanner extends StatelessWidget {
  final int failed;
  final int total;

  const PartialFailureBanner({required this.failed, required this.total});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '部分搜索失败（$failed/$total 路），结果可能不完整',
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),
        ],
      ),
    );
  }
}

/// tag 搜索命中非空时的截断说明：服务端 LIMIT 15、无游标，
/// `?by=tag&search=<tag>` 的服务端返回上限（该接口无游标/offset）。
///
/// 原先定义在已删除的 `tag_user_list_screen.dart`，本页仍在用它给「搜索框里
/// 打了标签名」那条路径标注截断，所以搬到这里。
const int kTagSearchLimit = 15;

/// 所以这里只有说明文字，没有"加载更多"。
class TagCapFooter extends StatelessWidget {
  /// 服务端（合并去重**前**）返回的条数，用于判断是否触顶。
  final int serverReturned;

  const TagCapFooter({required this.serverReturned});

  @override
  Widget build(BuildContext context) {
    final truncated = serverReturned >= kTagSearchLimit;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        truncated
            ? '已达服务端返回上限（$kTagSearchLimit 个，按标签权重降序），'
              '其余命中已被截断——该接口无分页'
            : '共 $serverReturned 个命中（服务端按标签权重降序，上限 $kTagSearchLimit）',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
    );
  }
}

/// 「部分标签没加载出来」的告警条。
///
/// 存在的理由是多选语义：选 A+B 时若只有 B 挂了，A 的结果**仍然要显示**
/// （否则加选一个冷门标签会把已取回的热门结果整个清掉），但必须说清楚
/// 「下面这份结果不完整，缺 B」——否则用户会以为这就是全部。
class PartialTagFailureBanner extends StatelessWidget {
  final String message;
  final List<String> failedTags;
  final VoidCallback onRetry;

  const PartialTagFailureBanner({
    super.key,
    required this.message,
    required this.failedTags,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFC978)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFE08600)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  failedTags.isEmpty
                      ? message
                      : '标签「${failedTags.join('、')}」没加载出来，下面是其余标签的结果',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF7A4B00)),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('重试失败标签'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// 标签筛选条：横向滚动的标签 cloud 芯片，点一下选中/取消。
///
/// **多选（并集）而非单选**，理由：标签天然是多维的——"女性"和"二次元"是
/// 正交的两个维度，单选强迫用户在"只要女性"和"只要二次元"之间二选一，而
/// "女性 + 二次元"这个组合恰恰是最常用的一类查询。多选还让"清空即全部"
/// 成为唯一需要的一个操作，交互更少。
///
/// 并集是**真的**并集：每个选中的标签都翻自己的全量名册，合并去重后展示
/// （见 UserListScreenState._loadTagUsers），不是只取第一个标签的名册再去
/// 本地过滤。
class TagFilterBar extends StatelessWidget {
  final List<TagCount> cloud;
  final Set<String> selected;
  final void Function(String tag) onToggle;
  final VoidCallback onClear;

  const TagFilterBar({
    required this.cloud,
    required this.selected,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    // 标签云为空 = 接口挂了或还没回来：整条隐藏，不给用户一排空壳。
    if (cloud.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                const Icon(Icons.filter_alt, size: 14, color: Colors.blue),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '已筛选：${selected.join(' / ')}',
                    style: const TextStyle(fontSize: 12, color: Colors.blue),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: onClear,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('清除', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final t in cloud)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: TagChip(
                    tag: t.tag,
                    // Count 就是该标签下的**人数**（见 TagCount.count）。
                    peopleText: '${t.count}',
                    selected: selected.contains(t.tag),
                    onTap: () => onToggle(t.tag),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单个筛选芯片。样式对齐 TagDisplayArea 的标签 chip（小圆角、淡底、描边）。
class TagChip extends StatelessWidget {
  final String tag;
  final String peopleText;
  final bool selected;
  final VoidCallback onTap;

  const TagChip({
    required this.tag,
    required this.peopleText,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.blue : Colors.grey;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected ? 0.15 : 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? color : color.withValues(alpha: 0.3),
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tag,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : null,
                color: selected ? Colors.blue.shade800 : Colors.grey.shade800,
              ),
            ),
            const SizedBox(width: 4),
            // 该标签下的**人数** —— 见 TagCount.count 的实测口径。
            Text(
              peopleText,
              style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标签全量列表尾部的"加载更多" + 如实的截断/人数说明。
class TagLoadMore extends StatelessWidget {
  final bool loading;
  final bool hasMore;
  final int loadedCount;
  final String? peopleText;
  final VoidCallback onMore;

  const TagLoadMore({
    required this.loading,
    required this.hasMore,
    required this.loadedCount,
    required this.onMore,
    this.peopleText,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Column(
        children: [
          if (hasMore)
            OutlinedButton.icon(
              onPressed: loading ? null : onMore,
              icon: loading
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more, size: 16),
              label: Text(loading ? '加载中...' : '加载更多'),
            ),
          const SizedBox(height: 6),
          Text(
            peopleText == null
                ? '已列出 $loadedCount 人'
                : '已列出 $loadedCount 人（该标签共 $peopleText 人）',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}


class SkeletonCircle extends StatefulWidget {
  const SkeletonCircle();
  @override
  State<SkeletonCircle> createState() => _SkeletonCircleState();
}

class _SkeletonCircleState extends State<SkeletonCircle>
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

class LoadMoreButton extends StatefulWidget {
  final String after;
  final TwitterApi api;
  final void Function(List<TwitterUser>) onLoaded;

  const LoadMoreButton({required this.after, required this.api, required this.onLoaded});

  @override
  State<LoadMoreButton> createState() => _LoadMoreButtonState();
}

class _LoadMoreButtonState extends State<LoadMoreButton> {
  bool _loading = false;

  Future<void> _loadMore() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final users = await widget.api.getUserListV2(after: widget.after);
      if (!mounted) return;
      // 参考 0.5.x：获取到新一页后立即回调更新列表，不阻塞等待 20+ 个 json.gz 下载
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
