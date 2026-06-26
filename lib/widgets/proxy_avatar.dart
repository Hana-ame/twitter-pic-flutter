import 'dart:typed_data';

// 通过 ECH 代理加载头像的组件
import 'package:flutter/material.dart';

import '../services/proxy_manager.dart';

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
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ProxyAvatar old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    if (widget.url == null) return;
    try {
      final bytes = await widget.proxy.fetchAsync(widget.url!);
      if (!mounted) return;
      setState(() => _bytes = bytes);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundImage: MemoryImage(_bytes!),
      );
    }
    return CircleAvatar(
      radius: widget.radius,
      child: Text(widget.fallbackText, style: TextStyle(fontSize: widget.radius * 0.8)),
    );
  }
}
