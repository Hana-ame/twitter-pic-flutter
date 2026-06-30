// 视频播放组件：下载后使用 OpenFilex 打开本地文件
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/proxy_manager.dart';

class TwitterVideo extends StatefulWidget {
  final String url;
  final ProxyManager proxy;

  const TwitterVideo({super.key, required this.url, required this.proxy});

  @override
  State<TwitterVideo> createState() => _TwitterVideoState();
}

class _TwitterVideoState extends State<TwitterVideo> {
  bool _loading = false;
  String? _error;
  String? _filePath;

  @override
  void initState() {
    super.initState();
    _download();
  }

  @override
  void didUpdateWidget(TwitterVideo old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _cleanup();
      _download();
    }
  }

  Future<void> _download() async {
    try {
      setState(() {
        _loading = true;
        _error = null;
      });

      final bytes = await widget.proxy.fetchAsync(widget.url);
      if (bytes == null || !mounted) return;

      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/tw_video_$ts.mp4');
      await file.writeAsBytes(bytes);

      if (!mounted) {
        file.delete();
        return;
      }

      setState(() {
        _filePath = file.path;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _play() async {
    if (_filePath == null) return;
    try {
      await launchUrl(Uri.file(_filePath!));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _cleanup() {
    if (_filePath != null) {
      File(_filePath!).delete();
      _filePath = null;
    }
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 32, color: Colors.red),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Colors.red.shade300, fontSize: 9),
                textAlign: TextAlign.center,
                maxLines: 3,
              ),
            ),
          ],
        ),
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        Container(color: Colors.black87),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie, size: 32, color: Colors.white54),
            const SizedBox(height: 4),
            Text('点击播放', style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 11)),
          ],
        ),
        IconButton(
          icon: const Icon(Icons.play_circle_fill, size: 48, color: Colors.white),
          onPressed: _play,
        ),
      ],
    );
  }
}