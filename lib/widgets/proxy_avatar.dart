// proxy_avatar.dart
// 通过本机 ECH 代理加载头像，代理失败自动降级直连。
//
// 与旧版差异：
//   - 删除了 fetchAsync → Image.memory 的手动流程
//   - 直接使用 CircleAvatar + Image.network(EchUrl.rewrite(...))
//   - 框架自动处理缓存、解码、错误状态
//   - 新增：加载指示器、错误回退、代理失败自动切直连

import 'package:flutter/material.dart';

import '../services/proxy_manager.dart';
import '../utils/ech_url.dart';

/// 头像加载通道：先走 ECH 代理，失败后自动降级到直连。
enum _UrlMode { proxy, direct }

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
  _UrlMode _mode = _UrlMode.proxy;
  int _retryCount = 0;

  @override
  void didUpdateWidget(ProxyAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.proxy.port != widget.proxy.port) {
      _mode = _UrlMode.proxy;
      _retryCount = 0;
    }
  }

  String _buildUrl() {
    final port = widget.proxy.port;
    if (_mode == _UrlMode.proxy && port != null && widget.url != null) {
      return EchUrl.rewrite(widget.url!, port);
    }
    return widget.url ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final port = widget.proxy.port;
    if (widget.url == null || (port == null && _mode == _UrlMode.proxy)) {
      return _buildFallback();
    }

    final echUrl = _buildUrl();

    return ClipOval(
      child: SizedBox(
        width: widget.radius * 2,
        height: widget.radius * 2,
        child: Image.network(
          echUrl,
          key: ValueKey('${echUrl}_$_retryCount'),
          fit: BoxFit.cover,
          width: widget.radius * 2,
          height: widget.radius * 2,
          errorBuilder: (context, error, stackTrace) {
            // 代理失败 → 直连；直连也失败 → 首字母占位。
            if (_mode == _UrlMode.proxy && port != null) {
              setState(() {
                _mode = _UrlMode.direct;
                _retryCount++;
              });
              return _buildFallbackInner();
            }
            return _buildFallback();
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
