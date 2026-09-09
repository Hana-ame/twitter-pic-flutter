// twitter_image.dart
// 图片组件：通过本机 ECH 代理加载，支持点击预览、下载、分享。
//
// 与旧版 (v0.2.8) 的差异：
//   - 删除了 fetchAsync → Image.memory 的手动流程
//   - 直接使用 Image.network(EchUrl.rewrite(url, port))
//   - 框架自动处理缓存、解码、错误状态
//   - 新增：点击全屏预览、下载、分享
//   - 新增：长按菜单（全屏查看、下载分享）

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/proxy_manager.dart';
import '../utils/ech_url.dart';

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
  int _retryCount = 0;

  void _showPreview() {
    if (widget.proxy.port == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ImageViewer(
          url: widget.url,
          proxy: widget.proxy,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final port = widget.proxy.port;
    if (port == null) {
      return _buildError('代理未启动');
    }

    final echUrl = EchUrl.rewrite(widget.url, port);

    return GestureDetector(
      onTap: _showPreview,
      onLongPress: () => _showContextMenu(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            echUrl,
            key: ValueKey(_retryCount),
            fit: widget.fit,
            width: widget.width,
            height: widget.height,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return Container(
                width: widget.width,
                height: widget.height,
                color: Colors.grey[200],
                child: const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            },
            errorBuilder: (context, error, stackTrace) {
              return _buildError(error.toString());
            },
          ),
        ],
      ),
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
    if (port == null) return;

    final echUrl = EchUrl.rewrite(widget.url, port);
    final uri = Uri.parse(echUrl);

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在下载...')));

    try {
      final client = HttpClient();
      final request = await client.getUrl(uri);
      final response = await request.close();
      final bytes = await response.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      final data = bytes.takeBytes();
      client.close();

      final tempDir = Directory.systemTemp;
      final fileName = widget.url.split('/').last.split('?').first;
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(data);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Twitter Image',
      );

      if (context.mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('已分享')));
      }
    } catch (e) {
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
    }
  }

  Widget _buildError(String message) {
    return Container(
      width: widget.width,
      height: widget.height,
      color: Colors.grey[300],
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image, size: 32, color: Colors.grey),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () => setState(() => _retryCount++),
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('重试', style: TextStyle(fontSize: 11)),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 0),
              ),
            ),
            const SizedBox(height: 4),
            Tooltip(
              message: message,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  message.length > 40 ? '${message.substring(0, 40)}...' : message,
                  style: const TextStyle(fontSize: 9, color: Colors.grey),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 全屏图片查看器
class _ImageViewer extends StatefulWidget {
  final String url;
  final ProxyManager proxy;

  const _ImageViewer({required this.url, required this.proxy});

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  bool _loading = true;
  String? _error;
  int _retryCount = 0;

  Future<void> _downloadAndShare() async {
    final port = widget.proxy.port;
    if (port == null) return;

    final echUrl = EchUrl.rewrite(widget.url, port);
    final uri = Uri.parse(echUrl);

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在下载...')));

    try {
      final client = HttpClient();
      final request = await client.getUrl(uri);
      final response = await request.close();
      final bytes = await response.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      final data = bytes.takeBytes();
      client.close();

      final tempDir = Directory.systemTemp;
      final fileName = widget.url.split('/').last.split('?').first;
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(data);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Twitter Image',
      );

      if (context.mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('已分享')));
      }
    } catch (e) {
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
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
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image, size: 48, color: Colors.white54),
            const SizedBox(height: 12),
            Text(
              '加载失败',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 4),
            SelectableText(
              _error ?? '',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => setState(() {
                _error = null;
                _loading = true;
              }),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return Center(
      child: InteractiveViewer(
        child: Image.network(
          EchUrl.rewrite(widget.url, widget.proxy.port!),
          key: ValueKey(_retryCount),
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          },
          errorBuilder: (context, error, stackTrace) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image, size: 48, color: Colors.white54),
                const SizedBox(height: 12),
                Text(
                  '加载失败',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  error.toString(),
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => setState(() {
                    _error = null;
                    _loading = true;
                    _retryCount++;
                  }),
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
