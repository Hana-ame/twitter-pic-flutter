// 视频组件：流式下载 + 下载完成后原地播放 + 封面。
//
// 流程：initState 即开始流式下载到临时 spool 文件（ECH 分块写盘，不占内存），
// 下载完成后原地播放（video_player）并抽首帧显示封面。
//
// 边下边播（下载中播本地流）经真机验证不可行，已移除：内置 ExoPlayer 对
// chunked 本地流不稳，系统播放器方案也无法可靠打开，统一"下载完才能看"。
// 桌面平台（video_player_win / Media Foundation）同样等下载完成播文件。
//
// 比例：播放中按视频实际 aspectRatio 自适应（限高 480），不用 16:9 硬框，
// 竖屏视频不会被拉伸。
//
// spool 完成标记：下载完成后写 <spool>.done，重进页面且标记存在才复用缓存，
// 避免"下载中断残留文件被误判为完整"；列表滚动 dispose 时保留 spool/.done，
// 同 URL 再次出现直接秒播。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../services/proxy_manager.dart';

class TwitterVideo extends StatefulWidget {
  final String url;
  final ProxyManager proxy;

  const TwitterVideo({super.key, required this.url, required this.proxy});

  @override
  State<TwitterVideo> createState() => _TwitterVideoState();
}

class _TwitterVideoState extends State<TwitterVideo> {
  bool _downloading = false;
  String? _error;
  String? _spoolPath;
  String? _thumbPath;
  bool _ready = false; // 下载完成（spool + .done 标记齐全）
  VideoPlayerController? _controller;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _controlsVisible = true; // 控制栏：播放中 3 秒无操作自动淡出
  Timer? _controlsTimer;
  int _lastSec = -1; // 播放进度秒数（秒级刷新，避免每帧 setState）
  int _bufferedBytes = 0; // 已下载字节（下载中进度显示）
  Timer? _progressTimer;
  bool _disposed = false;

  // 封面抽帧（video_thumbnail）仅 Android/iOS 有实现，桌面平台跳过。
  bool get _canThumb => !Platform.isWindows && !Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(TwitterVideo old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _teardown();
      _start();
    }
  }

  Future<void> _start() async {
    try {
      await _startInner();
    } catch (e) {
      // 前置步骤失败也要落到错误 UI，不能变成 unhandled async error。
      if (!_disposed && mounted) {
        setState(() {
          _downloading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _startInner() async {
    final dir = await getTemporaryDirectory();
    final hash = widget.url.hashCode.toRadixString(16);
    final spool = '${dir.path}/tw_$hash.mp4';
    final doneMark = '$spool.done';

    // 已有完整缓存（spool + .done 标记）→ 直接可播；
    // 下载中断留下的 spool（无标记）视为脏数据，重下。
    if (File(spool).existsSync() && File(doneMark).existsSync()) {
      setState(() {
        _spoolPath = spool;
        _ready = true;
      });
      _extractThumb();
      return;
    }
    setState(() {
      _spoolPath = spool;
      _downloading = true;
      _error = null;
    });
    if (File(spool).existsSync()) File(spool).deleteSync();
    _startProgressPoller();
    try {
      await widget.proxy.fetchToFileAsync(widget.url, spool);
      File(doneMark).writeAsStringSync('1');
      if (_disposed || !mounted) return;
      setState(() {
        _downloading = false;
        _ready = true;
      });
      _extractThumb();
    } catch (e) {
      if (File(spool).existsSync()) File(spool).deleteSync();
      if (File(doneMark).existsSync()) File(doneMark).deleteSync();
      if (!_disposed && mounted) {
        setState(() {
          _downloading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _play() async {
    if (_controller != null) {
      await _controller!.play();
      _scheduleControlsHide();
      return;
    }
    if (_spoolPath == null || !File(_spoolPath!).existsSync()) return;
    try {
      final c = VideoPlayerController.file(File(_spoolPath!));
      await c.initialize();
      _controller = c;
      c.addListener(_onPlayer);
      c.play();
      if (!mounted) {
        c.dispose();
        _controller = null;
        return;
      }
      setState(() {
        _isPlaying = true;
        _controlsVisible = true;
      });
      _scheduleControlsHide();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _onPlayer() {
    if (!mounted) return;
    final v = _controller!.value;
    final playing = v.isPlaying;
    final buffering = v.isBuffering;
    final sec = v.position.inSeconds;
    if (playing != _isPlaying) {
      // 播放/暂停切换：播放时重置 3 秒自动隐藏计时，暂停时保持控制栏显示。
      if (playing) {
        _scheduleControlsHide();
      } else {
        _controlsTimer?.cancel();
        if (!_controlsVisible) setState(() => _controlsVisible = true);
      }
    }
    // position 秒级变化也触发 setState，否则"秒数不跳"。
    if (playing != _isPlaying || buffering != _isBuffering || sec != _lastSec) {
      setState(() {
        _isPlaying = playing;
        _isBuffering = buffering;
        _lastSec = sec;
      });
    }
  }

  // 播放中 3 秒无操作自动隐藏控制栏（挡画面）；缓冲/暂停时保持显示。
  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_isPlaying && !_isBuffering) {
        setState(() => _controlsVisible = false);
      } else {
        _scheduleControlsHide(); // 缓冲中继续等待
      }
    });
  }

  // 点击视频区域：唤出/隐藏控制栏。
  void _toggleControls() {
    if (_controlsVisible) {
      _controlsTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      setState(() => _controlsVisible = true);
      _scheduleControlsHide();
    }
  }

  void _pause() {
    _controller?.pause();
  }

  // 下载中轮询 spool 文件大小，刷新进度文案。
  void _startProgressPoller() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (_downloading && _spoolPath != null) {
        try {
          final size = File(_spoolPath!).lengthSync();
          if (size != _bufferedBytes) {
            setState(() => _bufferedBytes = size);
          }
        } catch (_) {}
      }
    });
  }

  // 下载完成后抽首帧做封面（仅 Android/iOS）。
  Future<void> _extractThumb() async {
    if (!_canThumb || _spoolPath == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final thumb = '${dir.path}/tw_thumb_${widget.url.hashCode.toRadixString(16)}.jpg';
      if (File(thumb).existsSync()) {
        if (mounted) setState(() => _thumbPath = thumb);
        return;
      }
      final path = await VideoThumbnail.thumbnailFile(
        video: _spoolPath!,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 480,
        quality: 70,
        timeMs: 0,
      );
      if (path != null && mounted) setState(() => _thumbPath = path);
    } catch (_) {
      // 抽帧失败（编码不支持等）不影响播放。
    }
  }

  void _retry() {
    if (_spoolPath != null) {
      File('$_spoolPath.done').deleteSync();
      File(_spoolPath!).deleteSync();
    }
    _bufferedBytes = 0;
    _start();
  }

  void _teardown() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _controlsTimer?.cancel();
    _controlsTimer = null;
    _controller?.removeListener(_onPlayer);
    _controller?.dispose();
    _controller = null;
    _ready = false;
    _downloading = false;
    _isPlaying = false;
    _isBuffering = false;
    _thumbPath = null;
    // spool/.done 保留在临时目录：完整的缓存重进页面直接复用；
    // 中断残留（无标记）重进页面会被 _start 判脏重下。
  }

  @override
  void dispose() {
    _disposed = true;
    _teardown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 播放中：按视频实际比例自适应（限高），不用固定 16:9 硬框，
    // 否则竖屏视频（如 540x720）会被拉伸/裁切，比例不对。
    if (_controller != null) return _buildPlaying();
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

  Widget _buildPlaying() {
    final c = _controller!;
    final ratio = c.value.aspectRatio;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: AspectRatio(
          aspectRatio: ratio > 0 && ratio.isFinite ? ratio : 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              color: Colors.black,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: c.value.isInitialized
                          ? VideoPlayer(c)
                          : const CircularProgressIndicator(strokeWidth: 2),
                    ),
                    if (_isBuffering)
                      const Center(
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    // 控制栏：播放中 3 秒无操作淡出（AnimatedOpacity），
                    // 不遮挡视频画面；点视频唤出/隐藏。
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        ignoring: !_controlsVisible,
                        child: AnimatedOpacity(
                          opacity: _controlsVisible ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: _controlBar(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_downloading) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(strokeWidth: 2),
          const SizedBox(height: 8),
          Text(
            '下载中… ${_fmtBytes(_bufferedBytes)}',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 11),
          ),
        ],
      );
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
            TextButton(
              onPressed: _retry,
              child: const Text('重试', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      );
    }

    // 下载完成，未播放：显示封面缩略图 + 播放按钮。
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black87),
        if (_thumbPath != null)
          Image.file(File(_thumbPath!), fit: BoxFit.cover)
        else
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.movie, size: 32, color: Colors.white54),
                const SizedBox(height: 4),
                Text(
                  '点击播放',
                  style:
                      TextStyle(color: Colors.white.withAlpha(180), fontSize: 11),
                ),
              ],
            ),
          ),
        Center(
          child: IconButton(
            icon: const Icon(Icons.play_circle_fill,
                size: 48, color: Colors.white),
            onPressed: _play,
          ),
        ),
      ],
    );
  }

  Widget _controlBar() {
    final c = _controller!;
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              _isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 20,
            ),
            onPressed: _isPlaying ? _pause : () => _play(),
          ),
          Expanded(
            child: Text(
              '${_fmtDuration(c.value.position)} / ${_fmtDuration(c.value.duration)}',
              style: TextStyle(color: Colors.white.withAlpha(200), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static String _fmtDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
