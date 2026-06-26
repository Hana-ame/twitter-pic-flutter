// 图片展示组件：通过 ProxyManager 加载并缓存图片尺寸
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/proxy_manager.dart';

class TwitterImage extends StatefulWidget {
  final String url;
  final ProxyManager proxy;

  const TwitterImage({super.key, required this.url, required this.proxy});

  @override
  State<TwitterImage> createState() => _TwitterImageState();
}

class _TwitterImageState extends State<TwitterImage> {
  Uint8List? _bytes;
  bool _loading = true;
  String? _error;
  ui.Size? _imageSize;

  @override
  void initState() {
    super.initState();
    final cached = ProxyManager.sizeCache[widget.url];
    if (cached != null) _imageSize = cached;
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.proxy.fetchAsync(widget.url);
      if (!mounted) return;
      _bytes = bytes;
      _loading = false;
      if (bytes != null) _decodeSize(bytes);
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      _error = e.toString();
      _loading = false;
      setState(() {});
    }
  }

  Future<void> _decodeSize(Uint8List bytes) async {
    final size = await ProxyManager.decodeImageSize(bytes);
    if (size != null) {
      ProxyManager.sizeCache[widget.url] = size;
      if (mounted) setState(() => _imageSize = size);
    }
  }

  @override
  Widget build(BuildContext context) {
    double? height;
    if (_imageSize != null) {
      height = MediaQuery.of(context).size.width * _imageSize!.height / _imageSize!.width;
      height = height.clamp(100, 400);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        height: height ?? 200,
        color: Colors.grey.shade100,
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null || _bytes == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 32, color: Colors.red),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 8, right: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 10),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                ),
              ),
          ],
        ),
      );
    }
    return Image.memory(_bytes!, fit: BoxFit.contain);
  }
}