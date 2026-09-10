// twitter_image.dart
// 图片组件：通过本机 ECH 代理加载，支持点击预览、下载、分享。
//
// 布局要点（重要）：本组件挂在 ListView.builder 的 item 里，父级高度是
// **无界**的。因此绝不能把内容交给 `Stack(fit: StackFit.expand)` 去自适应
// ——expand 会把父级约束（height = ∞）作为紧约束传给子级，Image 在首帧未
// 解码时返回 Size(width, ∞)，整条 item 高度变成无穷，渲染直接失败、整片
// 媒体区域空白（这就是"看得到头像、看不到 media"的原因：头像用的是固定
// SizedBox，没这个问题）。
//
// 所以这里先用 AspectRatio 占一个确定的高度：
//   1. 立刻占位，滚动时列表高度稳定，不会"什么都没有"；
//   2. 图片解码出真实宽高比后换成真实比例（配合 BoxFit.cover，等于完整
//      显示且不留黑边）；
//   3. 加载中显示百分比进度——一边加载一边显示，而不是等全部就绪。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/proxy_manager.dart';
import '../utils/ech_url.dart';
import 'progressive_image.dart';

class TwitterImage extends StatefulWidget {
  /// 实际加载的 URL（列表里通常是缩略图变体）。
  final String url;

  /// 原图 URL：Hero 动画、下载、缩略图失败后的回退都用它。默认等于 [url]。
  final String? originalUrl;

  final ProxyManager proxy;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// 当前页面里所有图片的原始 URL（按时间线顺序），用于全屏预览时左右/上下
  /// 滑动翻页。为空时只预览当前这一张。
  final List<String>? gallery;

  /// 本图在 [gallery] 中的下标。
  final int galleryIndex;

  const TwitterImage({
    super.key,
    required this.url,
    required this.proxy,
    this.originalUrl,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.gallery,
    this.galleryIndex = 0,
  });

  @override
  State<TwitterImage> createState() => _TwitterImageState();
}

class _TwitterImageState extends State<TwitterImage> {
  /// 真实宽高比未知前先占的位（竖构图为主，接近常见推图比例）。
  static const double _kFallbackAspect = 3 / 4;

  /// 缩略图变体取不到时（CDN 不认这个 name=）回退到原图，最多回退一次。
  String? _displayOverride;

  String get _fullUrl => widget.originalUrl ?? widget.url;
  String get _displayUrl => _displayOverride ?? widget.url;

  double _aspect = _kFallbackAspect;
  int _retryCount = 0;
  bool _autoRetried = false;

  ImageStream? _sizeStream;
  ImageStreamListener? _sizeListener;
  String? _sizeUrl;

  @override
  void initState() {
    super.initState();
    // 代理可能比本组件晚就绪（启动时要先 DoH + ECH 初始化）：端口一出现
    // 就重新解析，否则第一帧永远停在"代理未启动"。
    widget.proxy.portNotifier.addListener(_onPortChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchSize();
  }

  @override
  void didUpdateWidget(TwitterImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.originalUrl != widget.originalUrl) {
      _aspect = _kFallbackAspect;
      _retryCount = 0;
      _autoRetried = false;
      _displayOverride = null;
      _sizeUrl = null;
      _watchSize();
    }
  }

  @override
  void dispose() {
    widget.proxy.portNotifier.removeListener(_onPortChanged);
    _detachSizeListener();
    super.dispose();
  }

  void _onPortChanged() {
    if (!mounted) return;
    _sizeUrl = null;
    _autoRetried = false;
    _watchSize();
    setState(() {});
  }

  String? _proxiedUrl() {
    final port = widget.proxy.port;
    if (port == null) return null;
    // 全部走 ECH 代理：EchUrl.rewrite 丢弃原始域名，代理统一拼
    // https://video-cf.twimg.com/<path>（图片与视频同通道）。
    return EchUrl.rewrite(_displayUrl, port);
  }

  void _detachSizeListener() {
    final stream = _sizeStream;
    final listener = _sizeListener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _sizeStream = null;
  }

  /// 解析真实宽高比：与下面 Image.network 用同一个 NetworkImage key，
  /// 命中 Flutter ImageCache 的同一份缓存，不会重复下载。
  void _watchSize() {
    final url = _proxiedUrl();
    if (url == null || url == _sizeUrl) return;
    _sizeUrl = url;
    _detachSizeListener();
    final stream = NetworkImage(url).resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        final h = info.image.height;
        if (h == 0) return;
        final ratio = info.image.width / h;
        if (ratio.isFinite && ratio > 0 && (ratio - _aspect).abs() > 0.001) {
          setState(() => _aspect = ratio);
        }
      },
      // 失败由 Image.network 的 errorBuilder 负责呈现，这里静默即可。
      onError: (_, __) {},
    );
    _sizeListener = listener;
    _sizeStream = stream;
    stream.addListener(listener);
  }

  void _retry() {
    setState(() {
      _retryCount++;
      _autoRetried = true;
      _sizeUrl = null;
    });
    _watchSize();
  }

  void _showPreview() {
    if (widget.proxy.port == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ECH 代理未启动，无法全屏预览')),
      );
      return;
    }

    final gallery = (widget.gallery == null || widget.gallery!.isEmpty)
        ? <String>[widget.url]
        : widget.gallery!;
    final initial = widget.galleryIndex.clamp(0, gallery.length - 1);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ImageViewer(
          gallery: gallery,
          initialIndex: initial,
          proxy: widget.proxy,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _proxiedUrl();
    if (url == null) {
      return _frame(
        child: const _StatusBox(message: 'ECH 代理未启动，无法加载图片'),
      );
    }

    return _frame(
      child: GestureDetector(
        onTap: _showPreview,
        onLongPress: () => _showContextMenu(context),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Hero(
              tag: 'img_${_fullUrl}',
              child: Image(
                image: ProgressiveImageProvider(url),
                key: ValueKey('$url#$_retryCount'),
                fit: widget.fit,
                width: widget.width,
                height: widget.height,
                // 已经收到的那部分照常画出来（child 就是逐块解码的中间帧），
                // 进度条只是叠在底部的一条细线——不是拿一块空白盖住整张图。
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  final total = progress.expectedTotalBytes;
                  final percent = (total != null && total > 0)
                      ? progress.cumulativeBytesLoaded / total
                      : null;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      child,
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: _ProgressOverlay(percent: percent),
                      ),
                    ],
                  );
                },
                errorBuilder: (context, error, stackTrace) {
                  // 首次失败自动重试一次；若加载的是缩略图变体，这次回退到
                  // 原图（万一 CDN 不认这个 name=，也不会一直报错）。
                  if (!_autoRetried) {
                    if (_displayOverride == null && _fullUrl != widget.url) {
                      _displayOverride = _fullUrl;
                    }
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _retry();
                    });
                    return const _StatusBox();
                  }
                  return _StatusBox(message: '加载失败：$error', onRetry: _retry);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 统一的定高外框：AspectRatio 给 ListView 一个确定高度，避免无界高度
  /// 把整条 item 撑成无穷大。
  Widget _frame({required Widget child}) {
    return AspectRatio(
      aspectRatio: _aspect,
      // 灰色底：JPEG 部分解码时，未下载到的部分本来就是中性灰，整体观感一致，
      // 不会在白色背景上突兀地出现半张图。
      child: ColoredBox(color: Colors.grey[200]!, child: child),
    );
  }

  void _showContextMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('图片操作', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.fullscreen),
              title: const Text('全屏查看'),
              onTap: () {
                Navigator.pop(ctx);
                _showPreview();
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载并分享'),
              onTap: () {
                Navigator.pop(ctx);
                _downloadAndShare();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadAndShare() async {
    final port = widget.proxy.port;
    if (port == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ECH 代理未启动，无法下载')),
      );
      return;
    }
    // 下载永远拿原图，而不是列表里的缩略图变体。
    final url = EchUrl.rewrite(_fullUrl, port);

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在下载...')));

    final file = await downloadToTempFile(Uri.parse(url), widget.url);
    if (file == null) {
      if (context.mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('下载失败')));
      }
      return;
    }
    await Share.shareXFiles([XFile(file.path)], subject: 'Twitter Image');
    if (context.mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('已分享')));
    }
  }
}

/// 经代理把 URL 落到临时文件；失败返回 null。
///
/// 与 widget 共用，保证"预览看到的"和"下载下来的"是同一条通道。
Future<File?> downloadToTempFile(Uri uri, String originalUrl) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != 200) return null;

    final fileName = originalUrl.split('/').last.split('?').first;
    final file = File('${Directory.systemTemp.path}/$fileName');
    final raf = await file.open(mode: FileMode.write);
    try {
      await for (final chunk in response) {
        await raf.writeFrom(chunk);
      }
    } finally {
      await raf.close();
    }
    return file;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// 叠在图片底部的一条细进度线 + 百分比。
///
/// 图片本身是"下到哪显示到哪"的，所以这不是遮罩，只是提示还剩多少没到。
class _ProgressOverlay extends StatelessWidget {
  final double? percent;
  final bool onDark;

  const _ProgressOverlay({this.percent, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: percent,
                minHeight: 3,
                backgroundColor: onDark ? Colors.white24 : Colors.black12,
                color: onDark ? Colors.white : Colors.black45,
              ),
            ),
          ),
          if (percent != null) ...[
            const SizedBox(width: 8),
            Text(
              '${(percent! * 100).clamp(0, 100).toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: 11,
                color: onDark ? Colors.white70 : Colors.black54,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 占位/进度/错误三合一的定高内容块。
class _StatusBox extends StatelessWidget {
  final String? message;
  final double? percent;
  final VoidCallback? onRetry;

  const _StatusBox({this.message, this.percent, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[200],
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message == null) ...[
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                value: percent,
                minHeight: 3,
                backgroundColor: Colors.grey[300],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              percent == null
                  ? '加载中…'
                  : '${(percent! * 100).clamp(0, 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ] else ...[
            const Icon(Icons.broken_image_outlined, size: 32, color: Colors.grey),
            const SizedBox(height: 8),
            Text(
              message!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  minimumSize: const Size(0, 32),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 全屏画廊：左右滑动或上下滑动翻页，双击放大/还原。
///
/// 刻意不用 InteractiveViewer：它的 scale 手势识别器会在手势竞技场里抢走
/// 单指拖动，导致 PageView 永远翻不了页（Flutter 的已知冲突）。这里改成
/// PageView 负责翻页、双击负责缩放，两者互不抢手势。
class _ImageViewer extends StatefulWidget {
  final List<String> gallery;
  final int initialIndex;
  final ProxyManager proxy;

  const _ImageViewer({
    required this.gallery,
    required this.initialIndex,
    required this.proxy,
  });

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late final PageController _pageController;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.gallery.length - 1);
    _pageController = PageController(initialPage: _index);
    // 预取下一张：翻过去就能立刻看到（本身也是逐块解码的）。
    // 必须等首帧之后再预取：precacheImage 会读 MediaQuery，initState 里
    // 依赖 InheritedWidget 会直接抛断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _precacheNeighbour(1);
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _precacheNeighbour(int delta) {
    final i = _index + delta;
    if (i < 0 || i >= widget.gallery.length) return;
    final port = widget.proxy.port;
    if (port == null) return;
    precacheImage(
      ProgressiveImageProvider(EchUrl.rewrite(widget.gallery[i], port)),
      context,
    ).catchError((_) {});
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.gallery.length) return;
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _downloadAndShare() async {
    final port = widget.proxy.port;
    if (port == null) return;
    final raw = widget.gallery[_index];
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在下载...')));
    final file =
        await downloadToTempFile(Uri.parse(EchUrl.rewrite(raw, port)), raw);
    if (file == null) {
      if (context.mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('下载失败')));
      }
      return;
    }
    await Share.shareXFiles([XFile(file.path)], subject: 'Twitter Image');
    if (context.mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('已分享')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${widget.gallery.length}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _downloadAndShare,
            tooltip: '下载并分享',
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
            tooltip: '关闭',
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.gallery.length,
        onPageChanged: (i) {
          setState(() => _index = i);
          _precacheNeighbour(1);
        },
        itemBuilder: (context, i) => GestureDetector(
          // PageView 只认水平拖动，竖直拖动没人抢，用它做"上下滑动翻页"。
          onVerticalDragEnd: (details) {
            final v = details.primaryVelocity ?? 0;
            if (v < -250) {
              _go(1); // 上滑 → 下一张
            } else if (v > 250) {
              _go(-1); // 下滑 → 上一张
            }
          },
          child: _GalleryPage(
            url: widget.gallery[i],
            proxy: widget.proxy,
            heroTag: i == widget.initialIndex ? 'img_${widget.gallery[i]}' : null,
          ),
        ),
      ),
    );
  }
}

/// 画廊里的一页：逐块解码 + 双击放大。
class _GalleryPage extends StatefulWidget {
  final String url;
  final ProxyManager proxy;
  final String? heroTag;

  const _GalleryPage({required this.url, required this.proxy, this.heroTag});

  @override
  State<_GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<_GalleryPage> {
  int _retryCount = 0;
  bool _zoomed = false;

  @override
  Widget build(BuildContext context) {
    final port = widget.proxy.port;
    if (port == null) {
      return const Center(
        child: Text('ECH 代理未启动', style: TextStyle(color: Colors.white70)),
      );
    }
    final url = EchUrl.rewrite(widget.url, port);

    Widget image = Image(
      image: ProgressiveImageProvider(url),
      key: ValueKey('$url#$_retryCount'),
      fit: BoxFit.contain,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        final total = progress.expectedTotalBytes;
        final percent = (total != null && total > 0)
            ? progress.cumulativeBytesLoaded / total
            : null;
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            Align(
              alignment: Alignment.bottomCenter,
              child: _ProgressOverlay(percent: percent, onDark: true),
            ),
          ],
        );
      },
      errorBuilder: (context, error, stackTrace) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image, size: 48, color: Colors.white54),
            const SizedBox(height: 12),
            const Text('加载失败',
                style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SelectableText(
                error.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => setState(() => _retryCount++),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );

    if (widget.heroTag != null) {
      image = Hero(tag: widget.heroTag!, child: image);
    }

    return GestureDetector(
      onDoubleTap: () => setState(() => _zoomed = !_zoomed),
      // ClipRect：放大后画面超出屏幕的部分不要盖到顶栏上。
      child: ClipRect(
        child: Center(
          child: Transform.scale(scale: _zoomed ? 2.5 : 1.0, child: image),
        ),
      ),
    );
  }
}
