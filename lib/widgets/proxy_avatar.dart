// proxy_avatar.dart
// 头像加载组件。
//
// 通道策略（按 URL 域名分流）：
//   - pbs.twimg.com / abs.twimg.com（头像/CDN 图片）：
//       → pbs.moonchan.xyz/<path>（moonchan 提供的 pbs 镜像，Cloudflare 直连可达）
//       → 失败后降级本机 ECH 代理 → 直连 → 首字母占位
//   - video-cf.twimg.com（视频/媒体）：
//       → 本机 ECH 代理（EchUrl.rewrite）
//       → 失败后直连 → 首字母占位
//
// 背景：video-cf.twimg.com 是视频 CDN，不含头像（profile_images 在
// pbs.twimg.com），且直连被墙只能走 ECH；而 pbs.moonchan.xyz 是
// moonchan 提供的 pbs 反向代理，可直连。

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
  // 当前尝试的候选通道下标；全部失败后显示首字母占位。
  int _attempt = 0;

  @override
  void didUpdateWidget(ProxyAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.proxy.port != widget.proxy.port) {
      _attempt = 0;
    }
  }

  /// 按域名生成候选 URL 列表（从优到劣）。
  List<String> _candidates() {
    final url = widget.url;
    if (url == null) return const [];
    final uri = Uri.parse(url);
    final path = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    final port = widget.proxy.port;

    // video-cf：ECH 代理 → 直连
    if (uri.host == 'video-cf.twimg.com') {
      return [
        if (port != null) EchUrl.rewrite(url, port),
        url,
      ];
    }
    // pbs/abs 等：pbs.moonchan.xyz 镜像 → ECH 代理 → 直连
    return [
      'https://pbs.moonchan.xyz$path',
      if (port != null) EchUrl.rewrite(url, port),
      url,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    if (url == null) return _buildFallback();

    final candidates = _candidates();
    if (_attempt >= candidates.length) return _buildFallback();

    final target = candidates[_attempt];

    return ClipOval(
      child: SizedBox(
        width: widget.radius * 2,
        height: widget.radius * 2,
        child: Image.network(
          target,
          key: ValueKey('${target}_$_attempt'),
          fit: BoxFit.cover,
          width: widget.radius * 2,
          height: widget.radius * 2,
          errorBuilder: (context, error, stackTrace) {
            // 当前通道失败 → 试下一个候选通道。
            if (_attempt < candidates.length - 1) {
              setState(() => _attempt++);
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
