// proxy_avatar.dart
// 头像加载组件。
//
// 通道策略：只有本机 ECH 代理一个通道。
//   EchUrl.rewrite 丢弃原始域名（pbs.twimg.com / video-cf.twimg.com / abs…），
//   代理统一拼 https://video-cf.twimg.com/<path> 再 ECH fetch。
//   代理未启动或加载失败 → 首字母占位。
//
// 背景：pbs.twimg.com 与 video-cf.twimg.com 在墙内直连都被封（实测 000），
// 但两者是同一 CDN 后端，改域名就能命中 video-cf.twimg.com 的 ECH 路径。
// 第三方镜像 pbs.moonchan.xyz 已弃用——不可靠，且会把请求导去未知节点。

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
  void initState() {
    super.initState();
    // 代理重启后端口变化：重置候选通道下标。否则头像一旦降级到直连就再
    // 也不会回到 ECH 通道——IndexedStack 不重建父级，didUpdateWidget 的
    // port 比对永不触发。
    widget.proxy.portNotifier.addListener(_onPortChanged);
  }

  void _onPortChanged() {
    if (mounted) setState(() => _attempt = 0);
  }

  @override
  void dispose() {
    widget.proxy.portNotifier.removeListener(_onPortChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(ProxyAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.proxy.port != widget.proxy.port) {
      _attempt = 0;
    }
  }

  /// 生成候选 URL 列表。
  ///
  /// 只有 ECH 代理一个通道：`EchUrl.rewrite` 丢弃原始域名，代理统一拼
  /// `https://video-cf.twimg.com/<path>` 再 ECH fetch。不尝试 pbs.twimg.com
  /// 直连（墙内必死，实测 000），也不依赖第三方镜像 pbs.moonchan.xyz。
  List<String> _candidates() {
    final url = widget.url;
    if (url == null) return const [];
    final port = widget.proxy.port;
    if (port != null) return [EchUrl.rewrite(url, port)];
    return const [];
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
          // 头像只需 radius*2 像素，避免为小圆形头像解码全尺寸图片浪费
          // 内存/CPU。
          cacheWidth: (widget.radius * 2).round(),
          cacheHeight: (widget.radius * 2).round(),
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
