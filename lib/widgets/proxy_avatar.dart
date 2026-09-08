// proxy_avatar.dart
// 通过本机 ECH 代理加载头像。
//
// 与旧版差异：
//   - 删除了 fetchAsync → Image.memory 的手手动流程
//   - 直接使用 CircleAvatar + Image.network(EchUrl.rewrite(...))
//   - 框架自动处理缓存、解码、错误状态

import 'package:flutter/material.dart';

import '../services/proxy_manager.dart';
import '../utils/ech_url.dart';

class ProxyAvatar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (url == null) {
      return CircleAvatar(
        radius: radius,
        child: Text(fallbackText, style: TextStyle(fontSize: radius * 0.8)),
      );
    }

    final port = proxy.port;
    if (port == null) {
      return CircleAvatar(
        radius: radius,
        child: Text(fallbackText, style: TextStyle(fontSize: radius * 0.8)),
      );
    }

    final echUrl = EchUrl.rewrite(url!, port);

    return CircleAvatar(
      radius: radius,
      backgroundImage: NetworkImage(echUrl),
      child: null,
    );
  }
}
