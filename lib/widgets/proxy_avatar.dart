// proxy_avatar.dart
// 通过本机 ECH 代理加载头像。
//
// 与旧版差异：
//   - 删除了 fetchAsync → Image.memory 的手手动流程
//   - 直接使用 CircleAvatar + Image.network(EchUrl.rewrite(...))
//   - 框架自动处理缓存、解码、错误状态
//   - 新增：加载指示器、错误回退

import 'package:flutter/material.dart';

import '../services/proxy_manager.dart';
import '../utils/ech_url.dart';

class ProxyAvatar extends StatefulWidget {
  final String? url;
  final String fallbackText;
  final double radius;
  final ProxyManager proxy;

  const ProxyAvatar({
    super.key,
    required this.url,
    required this.fallbackText,
    required this.proxy,
    this.radius = 16,
  });

  @override
  State<ProxyAvatar> createState() => _ProxyAvatarState();
}

class _ProxyAvatarState extends State<ProxyAvatar> {
  bool _error = false;

  @override
  void didUpdateWidget(ProxyAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.proxy.port != widget.proxy.port) {
      _error = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.url == null || widget.proxy.port == null || _error) {
      return _buildFallback();
    }

    final echUrl = EchUrl.rewrite(widget.url!, widget.proxy.port!);

    return ClipOval(
      child: SizedBox(
        width: widget.radius * 2,
        height: widget.radius * 2,
        child: Image.network(
          echUrl,
          fit: BoxFit.cover,
          width: widget.radius * 2,
          height: widget.radius * 2,
          errorBuilder: (context, error, stackTrace) {
            setState(() => _error = true);
            return _buildFallbackInner();
          },
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return _buildFallbackInner();
          },
        ),
      ),
    );
  }

  Widget _buildFallback() {
    return CircleAvatar(
      radius: widget.radius,
      child: Text(
        widget.fallbackText,
        style: TextStyle(fontSize: widget.radius * 0.8),
      ),
    );
  }

  Widget _buildFallbackInner() {
    return Container(
      width: widget.radius * 2,
      height: widget.radius * 2,
      color: Colors.grey[300],
      child: Center(
        child: Text(
          widget.fallbackText,
          style: TextStyle(fontSize: widget.radius * 0.8, color: Colors.white),
        ),
      ),
    );
  }
}
