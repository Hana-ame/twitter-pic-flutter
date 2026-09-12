// fullscreen_video.dart
// 全屏播放页。**复用卡片已经初始化好的 controller**（同一个 texture 只能被
// VideoPlayer 渲染一次 —— 所以进入全屏时卡片侧必须换成黑块，见 twitter_video.dart
// 的 _fullscreenOpen）。
//
// 从 twitter_video.dart 拆出来：那一度是 1700+ 行的文件，两套控制栏逻辑混在一起，
// 修一处漏一处（防重入守卫就只加在了这边，卡片侧隔了一版才补）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../services/log_service.dart';
import '../../services/proxy_manager.dart';
import '../../services/video_downloader.dart';
import '../../utils/ech_url.dart';
import 'video_slider_with_buffer.dart';

class FullscreenVideo extends StatefulWidget {
  final VideoPlayerController controller;
  final String url;
  final ProxyManager proxy;
  final VoidCallback onExit;

  const FullscreenVideo({
    super.key,
    required this.controller,
    required this.url,
    required this.proxy,
    required this.onExit,
  });

  @override
  State<FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<FullscreenVideo> {
  VideoPlayerValue? _videoValue;
  bool _showControls = true;
  Timer? _hideTimer;
  bool _downloading = false;
  double _playbackSpeed = 1.0;
  static const List<double> _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  int _speedIndex = 2;

  /// 播放器错误只记一次（通知是每帧来的）。
  bool _loggedError = false;

  /// 已缓冲比例（同卡片版）：全屏的进度条也把缓冲量画在轨道底下。
  double? get _bufferedFraction {
    final v = _videoValue;
    if (v == null || v.duration.inMilliseconds <= 0) return null;
    if (v.buffered.isEmpty) return null;
    final end = v.buffered.last.end.inMilliseconds;
    if (end <= 0) return null;
    final fraction = end / v.duration.inMilliseconds;
    if (fraction >= 0.999) return null;
    return fraction.clamp(0.0, 1.0);
  }

  /// 画面比例：未初始化/取不到时退回 16:9，避免 AspectRatio 拿到 NaN/0。
  double get _displayAspect {
    final ar = widget.controller.value.aspectRatio;
    if (!ar.isFinite || ar <= 0) return 16 / 9;
    return ar;
  }

  /// 排查用的一行状态：全屏若还是黑的，看这行就能判断是 texture 没拿到、
  /// 还是尺寸为 0、还是根本没在播。
  String get _playerStateLine {
    final v = widget.controller.value;
    return '${v.size.width.toInt()}x${v.size.height.toInt()} '
        '${v.isInitialized ? "init" : "uninit"}'
        '${v.isPlaying ? " play" : " pause"}'
        '${v.isBuffering ? " buf" : ""}';
  }

  Future<void> _downloadVideo() async {
    if (_downloading) return;
    // 代理没起来不能退回原始 URL（墙内直连必死），直接说清楚。
    final port = widget.proxy.port;
    if (port == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ECH 代理未就绪，暂时无法下载')),
      );
      return;
    }
    final uri = EchUrl.rewriteToUri(widget.url, port);

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _downloading = true);
    messenger.showSnackBar(const SnackBar(content: Text('正在下载视频...')));

    try {
      final file =
          await VideoDownloader.fetchToTemp(uri: uri, url: widget.url);
      await Share.shareXFiles([XFile(file.path)], subject: 'Twitter Video');
      if (context.mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('已分享')));
      }
    } catch (e) {
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onVideoUpdate);
    widget.controller.play();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _showControlsTemporarily();
  }

  void _onVideoUpdate() {
    if (!mounted) return;
    final v = widget.controller.value;
    // 全屏页不换画面（错误态由卡片侧负责），但错误必须留痕：否则"全屏拖进度条
    // 就黑屏"在日志里同样查不到。只记一次，避免每帧刷屏。
    if (v.hasError && !_loggedError) {
      _loggedError = true;
      LogService.recordError('player(fullscreen)', '${v.errorDescription}');
    }
    setState(() => _videoValue = v);
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
    _hideTimer?.cancel();
    setState(() => _showControls = true);
  }

  void _onSeekEnd(Duration value) {
    unawaited(_seek(value));
    _scheduleHideControls();
  }

  /// 同卡片版：seek 失败会以 PlatformException 回来，不接住就永远查不到。
  Future<void> _seek(Duration value) async {
    try {
      await widget.controller.seekTo(value);
    } catch (e, st) {
      LogService.recordError('seekTo(fullscreen)', e, st);
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _cycleSpeed() {
    setState(() {
      _speedIndex = (_speedIndex + 1) % _speeds.length;
      _playbackSpeed = _speeds[_speedIndex];
      widget.controller.setPlaybackSpeed(_playbackSpeed);
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

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onVideoUpdate);
    SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual, overlays: SystemUiOverlay.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 视频画面。
          //
          // 这里**不能**用 FittedBox 包 VideoPlayer：VideoPlayer 渲染的是一个
          // Texture，而 Flutter 的 Texture 是 sizedByParent（尺寸直接取
          // constraints.biggest）。FittedBox 会用无界约束去量孩子 → Texture
          // 拿到 height=∞，整层渲染失败，全屏就是一片黑。必须自己给一个有界
          // 尺寸：Center 先松约束，AspectRatio 按视频比例定尺寸。
          Positioned.fill(
            child: GestureDetector(
              onTap: _toggleControls,
              child: Center(
                child: AspectRatio(
                  aspectRatio: _displayAspect,
                  child: VideoPlayer(widget.controller),
                ),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: const BoxDecoration(
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
                    IconButton(
                      icon: _downloading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.download, color: Colors.white),
                      onPressed: _downloading ? null : _downloadVideo,
                      tooltip: '下载并分享',
                    ),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    VideoSliderWithBuffer(
                      value:
                          _videoValue?.position.inMilliseconds.toDouble() ?? 0,
                      max:
                          _videoValue?.duration.inMilliseconds.toDouble() ?? 1,
                      buffered: _bufferedFraction,
                      onStart: _onSeekStart,
                      onEnd: (v) =>
                          _onSeekEnd(Duration(milliseconds: v.toInt())),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(widget.controller.value.isPlaying
                              ? Icons.pause
                              : Icons.play_arrow),
                          onPressed: () => widget.controller.value.isPlaying
                              ? widget.controller.pause()
                              : widget.controller.play(),
                          color: Colors.white,
                          iconSize: 32,
                        ),
                        Text(
                          _formatDuration(widget.controller.value.position),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                        const Spacer(),
                        _buildSpeedButton(),
                        Text(
                          _formatDuration(widget.controller.value.duration),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _playerStateLine,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 9),
                          ),
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
