// twitter_video.dart
// 视频组件：通过本机 ECH 代理加载，支持流式播放、下载、分享。
//
// 与旧版 (v0.2.8) 的差异：
//   - 删除了 ECHFetchBegin/ECHRead 手动流式落盘
//   - 删除了 spool 文件、.done 标记、封面抽帧
//   - 直接使用 VideoPlayerController.networkUrl(EchUrl.rewrite(...))
//   - video_player 内部自动缓冲，支持边下边播
//   - 无需 isolate、无需手动进度跟踪
//   - 控制栏逻辑保留（自动淡出、拖动进度、全屏）
//   - 新增：下载、分享

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';

import '../services/proxy_manager.dart';
import '../utils/ech_url.dart';

class TwitterVideo extends StatefulWidget {
  final String url;
  final ProxyManager proxy;
  final double? width;
  final double? height;

  const TwitterVideo({
    super.key,
    required this.url,
    required this.proxy,
    this.width,
    this.height,
  });

  @override
  State<TwitterVideo> createState() => _TwitterVideoState();
}

class _TwitterVideoState extends State<TwitterVideo>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _controller;
  VideoPlayerValue? _videoValue;
  String? _error;
  bool _isLoading = true;
  bool _showControls = true;
  Timer? _hideTimer;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final port = widget.proxy.port;
    if (port == null) {
      setState(() {
        _error = '代理未启动';
        _isLoading = false;
      });
      return;
    }

    try {
      final echUrl = EchUrl.rewriteToUri(widget.url, port);
      _controller = VideoPlayerController.networkUrl(echUrl);
      await _controller!.initialize();

      _controller!.addListener(_onVideoUpdate);
      _controller!.setLooping(false);

      setState(() {
        _isLoading = false;
        _videoValue = _controller!.value;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _onVideoUpdate() {
    if (mounted && _controller != null) {
      setState(() => _videoValue = _controller!.value);
    }
  }

  void _togglePlay() {
    if (_controller == null) return;
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
  }

  void _seekTo(Duration duration) {
    _controller?.seekTo(duration);
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _showControlsTemporarily() {
    setState(() => _showControls = true);
    _scheduleHideControls();
  }

  void _toggleControls() {
    if (_showControls) {
      _hideTimer?.cancel();
      setState(() => _showControls = false);
    } else {
      _showControlsTemporarily();
    }
  }

  void _onSeekStart() {
    _isDragging = true;
    _hideTimer?.cancel();
    setState(() => _showControls = true);
  }

  void _onSeekEnd(Duration value) {
    _isDragging = false;
    _seekTo(value);
    _scheduleHideControls();
  }

  Future<void> _enterFullscreen() async {
    setState(() => _showControls = true);
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenVideo(
          controller: _controller!,
          onExit: () => Navigator.of(context).pop(),
        ),
      ),
    );
    _showControlsTemporarily();
  }

  Future<void> _downloadVideo() async {
    final port = widget.proxy.port;
    if (port == null) return;

    final echUrl = EchUrl.rewrite(widget.url, port);
    final uri = Uri.parse(echUrl);

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在下载视频...')));

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

      final tempDir = Directory.systemTemp;
      final fileName = widget.url.split('/').last.split('?').first;
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(data);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Twitter Video',
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

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_onVideoUpdate);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildLoading();
    }

    if (_error != null) {
      return _buildError(_error!);
    }

    return AspectRatio(
      aspectRatio: _videoValue?.aspectRatio ?? 16 / 9,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 视频画面
          GestureDetector(
            onTap: _toggleControls,
            onLongPress: () => _showContextMenu(context),
            child: VideoPlayer(_controller!),
          ),

          // 中央播放按钮（暂停时显示）
          if (!_controller!.value.isPlaying)
            GestureDetector(
              onTap: _togglePlay,
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow, size: 40, color: Colors.white),
              ),
            ),

          // 底部控制栏
          if (_showControls)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildControls(),
            ),
        ],
      ),
    );
  }

  // ─── 倍速播放 ──────────────────────────────────────────────────────────────
  double _playbackSpeed = 1.0;
  static const List<double> _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  int _speedIndex = 2;

  void _cycleSpeed() {
    setState(() {
      _speedIndex = (_speedIndex + 1) % _speeds.length;
      _playbackSpeed = _speeds[_speedIndex];
      _controller?.setPlaybackSpeed(_playbackSpeed);
    });
  }

  Widget _buildSpeedButton() {
    return IconButton(
      icon: const Icon(Icons.speed, color: Colors.white, size: 20),
      onPressed: _cycleSpeed,
      iconSize: 20,
      tooltip: '${_playbackSpeed}x',
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
              child: Text('视频操作', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载视频'),
              onTap: () {
                Navigator.pop(ctx);
                _downloadVideo();
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('分享视频'),
              onTap: () {
                Navigator.pop(ctx);
                _downloadVideo();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 进度条
          Slider(
            value: _videoValue?.position.inMilliseconds.toDouble() ?? 0,
            max: _videoValue?.duration.inMilliseconds.toDouble() ?? 1,
            onChanged: (v) => _onSeekStart(),
            onChangeEnd: (v) => _onSeekEnd(Duration(milliseconds: v.toInt())),
            activeColor: Colors.white,
            inactiveColor: Colors.white24,
          ),

          // 时间 + 按钮
          Row(
            children: [
              IconButton(
                icon: Icon(_controller!.value.isPlaying
                    ? Icons.pause : Icons.play_arrow),
                onPressed: _togglePlay,
                color: Colors.white,
                iconSize: 32,
              ),
              Text(
                _isDragging
                    ? _formatDuration(Duration(
                        milliseconds: (_controller!.value.position.inMilliseconds +
                                (_videoValue?.duration.inMilliseconds ?? 1) ~/ 2)))
                    : _formatDuration(_controller!.value.position),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const Spacer(),
              Text(
                _formatDuration(_controller!.value.duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const SizedBox(width: 8),
              _buildSpeedButton(),
              IconButton(
                icon: const Icon(Icons.download, color: Colors.white, size: 24),
                onPressed: _downloadVideo,
                iconSize: 24,
              ),
              IconButton(
                icon: const Icon(Icons.fullscreen, color: Colors.white, size: 24),
                onPressed: _enterFullscreen,
                iconSize: 24,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Container(
      width: widget.width,
      height: widget.height,
      color: Colors.black,
      child: const Center(child: CircularProgressIndicator(color: Colors.white)),
    );
  }

  Widget _buildError(String message) {
    return Container(
      width: widget.width,
      height: widget.height,
      color: Colors.grey[800],
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie, size: 48, color: Colors.white54),
            const SizedBox(height: 8),
            Text(
              '视频加载失败',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 4),
            SelectableText(
              message,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _error = null;
                  _isLoading = true;
                });
                _initPlayer();
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 全屏播放 ────────────────────────────────────────────────────────────────

class _FullscreenVideo extends StatefulWidget {
  final VideoPlayerController controller;
  final VoidCallback onExit;

  const _FullscreenVideo({required this.controller, required this.onExit});

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo>
    with SingleTickerProviderStateMixin {
  VideoPlayerValue? _videoValue;
  bool _showControls = true;
  Timer? _hideTimer;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onVideoUpdate);
    widget.controller.play();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _showControlsTemporarily();
  }

  void _onVideoUpdate() {
    if (mounted) setState(() => _videoValue = widget.controller.value);
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && widget.controller.value.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  void _showControlsTemporarily() {
    setState(() => _showControls = true);
    _scheduleHideControls();
  }

  void _toggleControls() {
    if (_showControls) {
      _hideTimer?.cancel();
      setState(() => _showControls = false);
    } else {
      _showControlsTemporarily();
    }
  }

  void _onSeekStart() {
    _isDragging = true;
    _hideTimer?.cancel();
    setState(() => _showControls = true);
  }

  void _onSeekEnd(Duration value) {
    _isDragging = false;
    widget.controller.seekTo(value);
    _scheduleHideControls();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onVideoUpdate);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 视频
          Positioned.fill(
            child: GestureDetector(
              onTap: _toggleControls,
              child: FittedBox(
                fit: BoxFit.contain,
                child: VideoPlayer(widget.controller),
              ),
            ),
          ),

          // 顶部栏
          if (_showControls)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: widget.onExit,
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ),

          // 底部控制栏
          if (_showControls)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Slider(
                      value: _videoValue?.position.inMilliseconds.toDouble() ?? 0,
                      max: _videoValue?.duration.inMilliseconds.toDouble() ?? 1,
                      onChanged: (v) => _onSeekStart(),
                      onChangeEnd: (v) =>
                          _onSeekEnd(Duration(milliseconds: v.toInt())),
                      activeColor: Colors.white,
                      inactiveColor: Colors.white24,
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(widget.controller.value.isPlaying
                              ? Icons.pause : Icons.play_arrow),
                          onPressed: () => widget.controller.value.isPlaying
                              ? widget.controller.pause()
                              : widget.controller.play(),
                          color: Colors.white,
                          iconSize: 32,
                        ),
                        Text(
                          _formatDuration(widget.controller.value.position),
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        const Spacer(),
                        Text(
                          _formatDuration(widget.controller.value.duration),
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
