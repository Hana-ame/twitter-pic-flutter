// twitter_image.dart
// 图片组件：通过本机 ECH 代理加载。
//
// 与旧版 (v0.2.8) 的差异：
//   - 删除了 fetchAsync → Image.memory 的手动流程
//   - 直接使用 Image.network(EchUrl.rewrite(url, port))
//   - 框架自动处理缓存、解码、错误状态
//   - 无需 isolate、无需手动 LRU 缓存

import 'package:flutter/material.dart';

import '../services/proxy_manager.dart';
import '../utils/ech_url.dart';

class TwitterImage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final port = proxy.port;
    if (port == null) {
      return _buildError('代理未启动');
    }

    final echUrl = EchUrl.rewrite(url, port);

    return Image.network(
      echUrl,
      fit: fit,
      width: width,
      height: height,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return SizedBox(
          width: width,
          height: height,
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
    );
  }

  Widget _buildError(String message) {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[300],
      child: Center(
        child: Tooltip(
          message: message,
          child: const Icon(Icons.broken_image, size: 32, color: Colors.grey),
        ),
      ),
    );
  }
}
