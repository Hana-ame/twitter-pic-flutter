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
  final String url;
  final ProxyManager proxy;
  final BoxFit fit;
  final double? width;
  final double? height;

  const TwitterImage({
    super.key,
    required this.url,
    required this.proxy,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
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
    if (old.url != widget.url) {
      _aspect = _kFallbackAspect;
      _retryCount = 0;
      _autoRetried = false;
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
    return EchUrl.rewrite(widget.url, port);
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

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ImageViewer(url: widget.url, proxy: widget.proxy),
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
              tag: 'img_${widget.url}',
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
                  // 首次失败自动重试一次（代理刚起来时容易撞上），之后交给
                  // 手动重试，避免无限重启请求风暴。
                  if (!_autoRetried) {
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
    final url = _proxiedUrl();
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ECH 代理未启动，无法下载')),
      );
      return;
    }

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

/// 全屏图片查看器（Scaffold body 有界，可安全用 Center 自适应）。
class _ImageViewer extends StatefulWidget {
  final String url;
  final ProxyManager proxy;

  const _ImageViewer({required this.url, required this.proxy});

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  int _retryCount = 0;

  String? _proxiedUrl() {
    final port = widget.proxy.port;
    if (port == null) return null;
    // 与主组件同通道：全部走 ECH 代理（video-cf.twimg.com）。
    return EchUrl.rewrite(widget.url, port);
  }

  Future<void> _downloadAndShare() async {
    final url = _proxiedUrl();
    if (url == null) return;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('图片预览'),
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
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final url = _proxiedUrl();
    if (url == null) {
      return const Center(
        child: Text('ECH 代理未启动', style: TextStyle(color: Colors.white70)),
      );
    }

    return Center(
      child: InteractiveViewer(
        child: Hero(
          tag: 'img_${widget.url}',
          child: Image(
            image: ProgressiveImageProvider(url),
            key: ValueKey('$url#$_retryCount'),
            fit: BoxFit.contain,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              final total = progress.expectedTotalBytes;
              final percent = (total != null && total > 0)
                  ? progress.cumulativeBytesLoaded / total
                  : null;
              // 全屏同样是"下到哪显示到哪"：中间帧照常铺满，进度在底部。
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
            errorBuilder: (context, error, stackTrace) {
              return Center(
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
              );
            },
          ),
        ),
      ),
    );
  }
}
