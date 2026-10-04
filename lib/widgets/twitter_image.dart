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

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';

import '../services/proxy_manager.dart';
import '../utils/ech_url.dart';
import '../utils/media_url.dart';
import '../utils/stable_hash.dart';
import 'progressive_image.dart';

/// 单次下载的整体预算。[HttpClient.connectionTimeout] 只管建连，
/// 上游已建连但响应体迟迟不吐数据（墙内常态）时不会触发。
const _kDownloadTimeout = Duration(seconds: 90);

class TwitterImage extends StatefulWidget {
  /// 实际加载的 URL（一律 origin，不做 name= 档位）。
  final String url;

  final ProxyManager proxy;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// 列表卡片模式：只用于**列表里的缩略图**，不是原图。
  ///
  /// v0.6.1：列表改拉 `name=small` 档位，一屏字节数掉到原来的 1/10 左右。
  /// 只有这个开关为true 时才走缩略图——全屏预览与详情页保持原图，否则预览
  /// 会变成"看的是缩略图"（放大就糊），下载分享也必须拿原图。
  ///
  /// 缩略图 URL 只影响**加载**，不影响 [gallery]：预览列表仍传原图 URL。
  final bool thumb;

  /// 当前页面里所有图片的原始 URL（按时间线顺序），用于全屏预览时左右/上下
  /// 滑动翻页。为空时只预览当前这一张。
  final List<String>? gallery;

  /// 本图在 [gallery] 中的下标。
  final int galleryIndex;

  const TwitterImage({
    super.key,
    required this.url,
    required this.proxy,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.thumb = false,
    this.gallery,
    this.galleryIndex = 0,
  });

  @override
  State<TwitterImage> createState() => _TwitterImageState();
}

class _TwitterImageState extends State<TwitterImage> {
  /// 真实宽高比未知前先占的位（竖构图为主，接近常见推图比例）。
  static const double _kFallbackAspect = 3 / 4;

  double _aspect = _kFallbackAspect;
  int _retryCount = 0;
  bool _autoRetried = false;

  /// 上次失败的原因；非空即表示当前处于错误态，此时把「重试」按钮画在
  /// Stack 顶层（独立于图片本体），保证它一定接得到点击。
  Object? _lastError;
  bool get _failed => _lastError != null;

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
    // thumb 也算"换了一张图"：档位一变，实际加载的 URL 就变了，尺寸探测
    // 与缓存 key 都必须跟着换，否则会拿缩略图的比例去裁原图。
    if (old.url != widget.url || old.thumb != widget.thumb) {
      _aspect = _kFallbackAspect;
      _retryCount = 0;
      _autoRetried = false;
      _sizeUrl = null;
      _lastError = null;
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
    _lastError = null;
    _watchSize();
    setState(() {});
  }

  /// 真正去加载的那个 URL（已按 [TwitterImage.thumb] 决定档位）。
  ///
  /// 分工：thumb=true → `name=small`（列表，便宜）；thumb=false → 原图
  /// （详情/预览，清楚）。缓存 key 天然分开，不会互相顶掉。
  String? _loadUrl() {
    final port = widget.proxy.port;
    if (port == null) return null;
    final target = widget.thumb ? MediaUrl.thumbOf(widget.url) : widget.url;
    // 全部走 ECH 代理：EchUrl.rewrite 丢弃原始域名，代理统一拼
    // https://video-cf.twimg.com/<path>（图片与视频同通道）。
    return EchUrl.rewrite(target, port);
  }

  void _detachSizeListener() {
    final stream = _sizeStream;
    final listener = _sizeListener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _sizeStream = null;
  }

  /// 解析真实宽高比。用和显示处**同一个** ProgressiveImageProvider（按 url
  /// 判等，见 progressive_image.dart），命中 Flutter ImageCache 的同一份
  /// completer，探测不会额外触发一次下载。
  /// 这里**不能**用 NetworkImage：不同 provider 类型就是不同的缓存 key，
  /// 同一张图会被下载两遍。原注释声称两者共享缓存，是错的。
  void _watchSize() {
    final url = _loadUrl();
    if (url == null || url == _sizeUrl) return;
    _sizeUrl = url;
    _detachSizeListener();
    final stream = ProgressiveImageProvider(url, retry: _retryCount)
        .resolve(createLocalImageConfiguration(context));
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
      // 失败由显示处 Image 的 errorBuilder 负责呈现，这里静默即可。
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
      _lastError = null;
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
    final url = _loadUrl();
    if (url == null) {
      return _frame(
        child: const _StatusBox(message: 'ECH 代理未启动，无法加载图片'),
      );
    }

    return _frame(
      // 手势只挂在"图片本体"上，不挂在整块区域上：错误态的「重试」按钮在
      // 这块区域内部，而外层 onLongPress 会让长按识别器一直占着手势竞技场
      // （要等到 ~500ms 超时才结算），嵌套按钮的 tap 因此在点击判定窗口内
      // 永远拿不到胜出权——表现就是"按钮看得见、按下去毫无反应"（不高亮、
      // 不回调）。把打开预览/长按菜单下移到 Stack 的图片层，按钮就不再与
      // 任何祖先手势竞争。
      child: Stack(
        fit: StackFit.expand,
        children: [
          Hero(
            tag: 'img_${widget.url}',
            child: GestureDetector(
              onTap: _showPreview,
              onLongPress: () => _showContextMenu(context),
              child: Image(
                image: ProgressiveImageProvider(url, retry: _retryCount),
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
                  // 首次失败自动重试一次（代理可能刚起来或抽了一下），
                  // 再失败就交给用户手动重试。
                  if (!_autoRetried) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _retry();
                    });
                    return const _StatusBox();
                  }
                  // 图片层在错误态下画一个空的撑满块：真正的「加载失败 + 重试」
                  // 界面由上面 Stack 顶层那个 _StatusBox 负责（它不被任何手势
                  // 识别器包着，按钮才按得动）。这里用 postFrame 回调把错误记进
                  // state，避免在 build 期间直接 setState。
                  if (_lastError == null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && _lastError == null) {
                        setState(() => _lastError = error);
                      }
                    });
                  }
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
          if (_failed)
            // 顶层错误态：不透明地盖住图片层。
            //
            // 这里**绝不能**再套任何带 onTap/onLongPress 的祖先——哪怕只挂
            // onLongPress 也不行：长按识别器会一直占着手势竞技场直到 ~500ms
            // 超时，嵌套的重试按钮就永远等不到 tap 胜出（这正是原来"按钮看
            // 得见按不到"的成因）。错误态下预览/长按菜单暂时不可用，等重试
            // 成功回到图片层即可恢复。
            Positioned.fill(
              child: _StatusBox(
                message: '加载失败：$_lastError',
                onRetry: _retry,
              ),
            ),
        ],
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
    final url = EchUrl.rewrite(widget.url, port);

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
  // HttpClient 没有请求级超时，只有 connectionTimeout。这里用定时器强关
  // client：force close 会让在途请求以错误结束，await 抛错后走 catch 返回 null。
  final deadline = Timer(_kDownloadTimeout, () {
    client.close(force: true);
  });
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != 200) return null;

    // 文件名不能直接取 URL 末段：不同用户/不同路径很容易同名（1.jpg、
    // default.png），后下的会覆盖前下的，用户分享时拿到的是别人的图。
    // 拼上 URL 的稳定哈希，并顺手把路径分隔符等非文件名字符清掉。
    final raw = originalUrl.split('/').last.split('?').first;
    final safeBase = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final fileName =
        'twitter_${stableHash(originalUrl)}_${safeBase.isEmpty ? 'file' : safeBase}';
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
    deadline.cancel();
    client.close(force: true);
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

/// 全屏相册：左右滑动翻页，双击放大，**放大后单指拖动是平移图片**。
///
/// v0.6.4：这一整套原先是手写的（PageView + GestureDetector + Transform.scale），
/// 换来的是一串互相打架的手势：放大后拖动会翻到下一张，而不是平移图片。
/// 根因是 Flutter 的手势竞技场里，「缩放识别器」与「翻页识别器」互相抢——手写
/// 只能做"二选一"（要么禁用翻页、要么切手势），做不出「放大态归图片、
/// 原图态归翻页」这套**状态机**。photo_view 内置了它，于是直接用它。
///
/// 取流仍然走本机 ECH 代理：`ProgressiveImageProvider(EchUrl.rewrite(...))`，
/// 没有引入第二个网络栈（这也是不选 extended_image 的原因，见 pubspec 注释）。
///
/// 保留的既有能力：Hero 过渡、逐块解码、失败重试、下载分享、邻张预取。
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

  /// 每页一个 controller：照片视图的缩放状态挂在它上面，页内双击/缩放由此驱动。
  ///
  /// 刻意不用一个共享 controller —— 共享会让翻页后新图片继承上一页的缩放
  /// 比例（翻到第 5 张结果还保持着第 3 张放大的状态）。
  late final List<PhotoViewController> _controllers;
  late final List<int> _retryCounts;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.gallery.length - 1);
    _pageController = PageController(initialPage: _index);
    _controllers = List.generate(
      widget.gallery.length,
      (_) => PhotoViewController(),
    );
    _retryCounts = List.generate(widget.gallery.length, (_) => 0);
    // 预取邻张：翻过去就能立刻看到。必须等首帧之后 —— precacheImage 要读
    // MediaQuery，在 initState 里依赖 InheritedWidget 会直接抛断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _precacheNeighbour(1);
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in _controllers) {
      c.dispose();
    }
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
    final port = widget.proxy.port;
    if (port == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black),
        body: const Center(
          child: Text('ECH 代理未启动，无法打开相册',
              style: TextStyle(color: Colors.white70)),
        ),
      );
    }

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
      body: PhotoViewGallery.builder(
        pageController: _pageController,
        itemCount: widget.gallery.length,
        onPageChanged: (i) {
          setState(() => _index = i);
          _precacheNeighbour(1);
        },
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        // 原图态：左右拖 = 翻页；双击 = 放大。放大后由 photo_view 接管，
        // 单指拖动变成平移图片，到边才交还给翻页（tightMode 的仲裁）。
        loadingBuilder: (context, event) => const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white54),
          ),
        ),
        builder: (context, index) {
          final raw = widget.gallery[index];
          final proxied = EchUrl.rewrite(raw, port);
          final retry = _retryCounts[index];
          return PhotoViewGalleryPageOptions(
            imageProvider: ProgressiveImageProvider(proxied, retry: retry),
            controller: _controllers[index],
            // 只有打开时的那一页参与 Hero 过渡；其余页没有来源，强行给
            // 同名 tag 会在翻页瞬间抛出重复 tag 断言。
            heroAttributes: index == widget.initialIndex
                ? PhotoViewHeroAttributes(tag: 'img_$raw')
                : null,
            minScale: PhotoViewComputedScale.contained,
            initialScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 4,
            // 双击在 1x 与 2.5x 之间切；点一下空白处关掉相册是列表那边的行为，
            // 这里 onTapUp 交给 PhotoView 默认（无操作），避免与双击抢。
            onTapUp: (context, details, controller) {},
            errorBuilder: (context, error, stackTrace) => _GalleryError(
              error: error,
              onRetry: () => setState(() => _retryCounts[index]++),
            ),
          );
        },
      ),
    );
  }
}

/// 相册里单页的错误态：黑底 + 错误详情 + 一定能按动的「重试」。
///
/// 独立成 widget 的原因：它是 PhotoView 的 errorBuilder 回调内容，**不在**
/// PhotoView 的手势识别器内部，所以重试按钮不会被缩放/拖动手势吞掉。
/// （此前手写版本把它画在 GestureDetector 里，出现过「看得见按不到」。）
class _GalleryError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _GalleryError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
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
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      ],
    );
  }
}
