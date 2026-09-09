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
  bool _isLoading = false;
  String? _error;

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
              onTap: () => Navigator.pop(ctx),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
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
            Tooltip(
              message: message,
              child: ElevatedButton.icon(
                onPressed: () => setState(() {}),
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('重试', style: TextStyle(fontSize: 11)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 0),
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
class _ImageViewer extends StatelessWidget {
  final String url;
  final ProxyManager proxy;

  const _ImageViewer({required this.url, required this.proxy});

  Future<void> _downloadAndShare(BuildContext context) async {
    final port = proxy.port;
    if (port == null) return;

    final echUrl = EchUrl.rewrite(url, port);
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

      // 保存到临时目录
      final tempDir = Directory.systemTemp;
      final fileName = url.split('/').last.split('?').first;
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(data);

      // 分享
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
            onPressed: () => _downloadAndShare(context),
            tooltip: '下载并分享',
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
            tooltip: '关闭',
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.network(
            EchUrl.rewrite(url, proxy.port!),
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
