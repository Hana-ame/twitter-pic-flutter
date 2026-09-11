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

import '../services/log_service.dart';
import '../services/proxy_manager.dart';
import '../utils/ech_url.dart';
import '../utils/video_failure.dart';

/// 首次加载多久算超时。
///
/// 取值依据：新进程里第一次 ECH 请求要 7~11s（先通过 DoH 取 ECH 配置），
/// 15s 是"放冷启动过去、又不让用户对着转圈干等"的位置。
const Duration _kLoadTimeout = Duration(seconds: 15);

/// 自动重试前的等待：给抖动的连接一点恢复时间。
const Duration _kAutoRetryDelay = Duration(milliseconds: 1200);

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
  bool _downloading = false;
  /// 全屏播放中：卡片侧不再渲染 VideoPlayer（同一 controller 只能渲染一次）。
  bool _fullscreenOpen = false;

  /// 待机：被播放器池收回了槽位，或代理还没就绪。点一下才去加载。
  bool _idle = false;

  /// 加载看门狗：`initialize()` 自己没有超时，代理卡住时就是无限转圈 ——
  /// 既没有提示也没有出口，用户只能退出重进。
  Timer? _loadWatchdog;

  /// 首次失败后自动重试一次（ECH 冷启动 7~11s、连接抖动多半是一次性的）。
  bool _autoRetried = false;

  /// 正在自动重试：loading 文案里体现，避免"卡住不动"的观感。
  bool _retrying = false;

  /// 上次失败是不是解码器类（决定重试前要不要先释放其它播放器）。
  bool _lastErrorWasCodec = false;

  /// 技术细节。卡片上只显示人话，细节留给「详情」按钮与日志。
  String? _errorDetail;

  /// 初始化序号：只有最新一次 init 的回调才允许改状态。
  ///
  /// 没有它，"端口变化触发 portNotifier + 父级重建触发 didUpdateWidget" 会
  /// 同时留下两个 in-flight 的 `initialize()` —— 旧的那个会写到新 controller 上，
  /// 而且**白白多吃一个解码器**（正是本次要修的资源问题）。
  int _initSeq = 0;

  /// 同一轮里多次请求初始化时合并成一次（见 [_scheduleInit]）。
  bool _initScheduled = false;

  Uri _buildUrl() {
    final port = widget.proxy.port;
    // 不降级直连：墙内直连 twimg 必死（实测 000）。那样只会把一个失败换成
    // 另一个失败，还让用户看不出原因。抛出去，由上层给出可操作的提示。
    if (port == null) throw const VideoProxyNotReady();
    return EchUrl.rewriteToUri(widget.url, port);
  }

  @override
  void initState() {
    super.initState();
    // 代理重启后端口会变（也可能从 null 变成有值）。没有这个监听，视频会一直
    // 停在错误态不动 —— 因为 IndexedStack/列表不会因为端口变化而重建。
    widget.proxy.portNotifier.addListener(_onPortChanged);
    _scheduleInit();
  }

  @override
  void didUpdateWidget(TwitterVideo old) {
    super.didUpdateWidget(old);
    if (old.proxy != widget.proxy) {
      old.proxy.portNotifier.removeListener(_onPortChanged);
      widget.proxy.portNotifier.addListener(_onPortChanged);
    }
    if (old.url != widget.url || old.proxy.port != widget.proxy.port) {
      _disposeController();
      _videoValue = null;
      _error = null;
      _errorDetail = null;
      _isLoading = true;
      _idle = false;
      _showControls = true;
      _hideTimer?.cancel();
      _isDragging = false;
      _autoRetried = false;
      _scheduleInit();
    }
  }

  /// 代理端口出现/变化时自动重试一次：端口变化意味着代理刚起来或刚重启，
  /// 之前那次失败已经过期了。
  void _onPortChanged() {
    if (!mounted) return;
    if (widget.proxy.port == null) return;
    if (_error == null && !_idle) return;
    _autoRetried = false;
    _retryInit();
  }

  /// 合并同一轮内的多次初始化请求。
  ///
  /// 触发源可能叠加：初始构建、父级重建（`didUpdateWidget`）、代理端口变化
  /// （`portNotifier`）、自动重试、手动重试。都直接调 `_initPlayer()` 的话，
  /// 同一帧里会起两个播放器、两个解码器。
  void _scheduleInit() {
    if (_initScheduled) return;
    _initScheduled = true;
    scheduleMicrotask(() {
      _initScheduled = false;
      if (!mounted) return;
      _initPlayer();
    });
  }

  Future<void> _initPlayer() async {
    final seq = ++_initSeq;
    _loadWatchdog?.cancel();
    _loadWatchdog = Timer(_kLoadTimeout, () {
      // 只有当前这次尝试才有资格报超时。
      if (seq == _initSeq) _onLoadTimeout();
    });

    try {
      final url = _buildUrl();
      final controller = VideoPlayerController.networkUrl(url);
      _controller = controller;
      await controller.initialize();

      // initialize 期间视频可能已滚出列表被 dispose，或被更新的一次初始化取代；
      // 两种情况都必须先判，否则触发 "setState() called after dispose()" 崩溃，
      // 或者把旧结果写到新 controller 上。
      if (!mounted || seq != _initSeq) {
        unawaited(controller.dispose());
        if (identical(_controller, controller)) _controller = null;
        return;
      }

      _loadWatchdog?.cancel();
      controller.addListener(_onVideoUpdate);
      controller.setLooping(false);

      setState(() {
        _isLoading = false;
        _retrying = false;
        _idle = false;
        // 看门狗先报了超时、底层后来才成功：把错误态收回来，换成播放器。
        _error = null;
        _errorDetail = null;
        _videoValue = controller.value;
      });
      // 登记进池子：超过上限会回收最久未用的那个（见 _PlayerPool 的注释）。
      _PlayerPool.touch(this);
    } catch (e, st) {
      if (!mounted || seq != _initSeq) return;
      _loadWatchdog?.cancel();
      _logFailure(e, st);

      // 自动重试一次：冷启动（新进程首次 ECH 要 7~11s）与连接抖动多为一次性，
      // 直接甩错误态会显得"经常加载失败"。
      if (!_autoRetried) {
        _autoRetried = true;
        setState(() => _retrying = true);
        await Future.delayed(_kAutoRetryDelay);
        if (!mounted || seq != _initSeq) return;
        _disposeController();
        _scheduleInit();
        return;
      }

      _lastErrorWasCodec = _looksLikeCodecError(e);
      _fail(_humanize(e), '$e');
    }
  }

  /// 看门狗：只切状态，**不打断**底层 initialize。
  ///
  /// 真慢但最终能成的话，成功回调会把错误态清掉、自动切回播放器（见上面成功分支）。
  void _onLoadTimeout() {
    if (!mounted || !_isLoading) return;
    final port = widget.proxy.port;
    _fail(
      port == null
          ? 'ECH 代理未就绪（还没启动或刚重启）。等代理就绪后点重试。'
          : '加载超时（${_kLoadTimeout.inSeconds} 秒没有响应）。点重试，'
              '或在设置页看代理状态与通道测试。',
      'initialize() timeout, proxyPort=${port ?? '-'}',
    );
  }

  /// 统一的失败落点（保证看门狗停掉、loading 关掉）。
  void _fail(String message, String? detail) {
    _loadWatchdog?.cancel();
    if (!mounted) return;
    setState(() {
      _error = message;
      _errorDetail = detail;
      _isLoading = false;
      _retrying = false;
      _idle = false;
    });
  }

  /// MediaCodec 类失败（分类逻辑与文案见 utils/video_failure.dart，那边有测试）。
  static bool _looksLikeCodecError(Object e) => VideoFailure.isCodecError(e);

  /// 把技术错误翻成一句能行动的话。原始细节进「详情」与日志。
  String _humanize(Object e) => VideoFailure.humanize(e);

  /// 原始错误里带着 ExoPlayer 的 Format（编码/分辨率/帧率）与
  /// `format_supported`，是区分"解码器不够"和"网络失败"的唯一线索，
  /// 必须原样留下来 —— 否则报告里只剩一句"加载失败"。
  void _logFailure(Object e, StackTrace st) {
    LogService.recordError(
      'video.init',
      'url=${widget.url}\nproxyPort=${widget.proxy.port ?? '-'}\n$e',
      st,
    );
  }

  void _onVideoUpdate() {
    final c = _controller;
    if (!mounted || c == null) return;
    final v = c.value;
    setState(() {
      _videoValue = v;
      // 播放器自己报错（解码器失败、seek 拉不到数据）时以前**什么都不显示**：
      // 画面就那么黑着/卡着，用户只能说"拖完进度条就废了"，日志里也没有痕迹。
      if (v.hasError && _error == null) {
        final desc = '${v.errorDescription}';
        _lastErrorWasCodec = _looksLikeCodecError(desc);
        _error = _humanize(desc);
        _errorDetail = desc;
        LogService.recordError('player', desc);
      }
    });
  }

  void _togglePlay() {
    if (_controller == null) return;
    // 用户在用的这个不该被池子回收。
    _PlayerPool.touch(this);
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
  }

  /// 释放当前 controller（重试 / 重建 / 被池子回收都走这里）。
  void _disposeController() {
    // 作废在飞的初始化：它的回调即使回来也不许再改状态。
    _initSeq++;
    _loadWatchdog?.cancel();
    final old = _controller;
    _controller = null;
    if (old != null) {
      old.removeListener(_onVideoUpdate);
      unawaited(old.dispose());
    }
    _PlayerPool.remove(this);
  }

  /// 被池子回收：释放解码器，回到待机态。
  ///
  /// **不落到错误态**：这是主动让位而不是失败，否则用户会看到满屏"加载失败"，
  /// 而实际上点一下就能播。
  void _releaseForPool() {
    if (!mounted) return;
    _disposeController();
    setState(() {
      _videoValue = null;
      _isLoading = false;
      _retrying = false;
      _error = null;
      _errorDetail = null;
      _idle = true;
    });
  }

  bool get _isPlayingNow => _controller?.value.isPlaying ?? false;

  /// seek 失败必须留痕。
  ///
  /// 之前是 `_controller?.seekTo(duration);` —— 返回的 Future 既不 await 也不
  /// catch。Android 上 seek 失败会变成 PlatformException（pigeon 把
  /// Throwable 包成错误回给 Dart），于是被无声吞掉：「拖了没反应」且无从查起。
  /// 不弹窗：一次性拉不到目标位置很常见，弹窗只会变成噪音。
  Future<void> _seekTo(Duration duration) async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.seekTo(duration);
    } catch (e, st) {
      LogService.recordError('seekTo', e, st);
    }
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
    // _seekTo 内部自己 catch，不会变成未处理的异步错误。
    unawaited(_seekTo(value));
    _scheduleHideControls();
  }

  Future<void> _enterFullscreen() async {
    // 同一个 controller 只能有一个 VideoPlayer 在渲染：卡片和全屏同时挂着
    // 会共用同一个 texture，表现为鬼影/花屏，全屏还可能是黑的。全屏期间把
    // 卡片这侧的 VideoPlayer 换成纯黑占位。
    setState(() {
      _showControls = true;
      _fullscreenOpen = true;
    });
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenVideo(
          controller: _controller!,
          url: widget.url,
          proxy: widget.proxy,
          onExit: () => Navigator.of(context).pop(),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _fullscreenOpen = false);
    _showControlsTemporarily();
  }

  Future<void> _downloadVideo() async {
    // 防重入：控制栏按钮 + 长按菜单可并发触发，同名临时文件被两个
    // RandomAccessFile 同时写会损坏（全屏版已有该守卫）。
    if (_downloading) return;

    // 代理没起来就直接说清楚：以前会静默退回原始 URL（墙内必死），
    // 用户只会看到"下载失败"却不知道为什么。
    final proxyPort = widget.proxy.port;
    if (proxyPort == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ECH 代理未就绪，暂时无法下载')),
      );
      return;
    }

    setState(() => _downloading = true);

    final uri = _buildUrl();

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在下载视频...')));

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);
      try {
        final request = await client.getUrl(uri);
        final response = await request.close();
        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }

        final tempDir = Directory.systemTemp;
        final fileName = widget.url.split('/').last.split('?').first;
        final file = File('${tempDir.path}/$fileName');
        RandomAccessFile? raf;
        try {
          final handle = await file.open(mode: FileMode.write);
          raf = handle;
          await for (final chunk in response) {
            await handle.writeFrom(chunk);
          }
          await handle.close();
          raf = null;
        } catch (_) {
          // 写入失败（磁盘满/连接中断）：关闭句柄并清理半写文件。
          if (raf != null) {
            try {
              await raf.close();
            } catch (_) {}
          }
          await file.delete();
          rethrow;
        }

        await Share.shareXFiles(
          [XFile(file.path)],
          subject: 'Twitter Video',
        );

        if (context.mounted) {
          messenger.showSnackBar(const SnackBar(content: Text('已分享')));
        }
      } finally {
        client.close();
      }
    } catch (e) {
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
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
    _loadWatchdog?.cancel();
    widget.proxy.portNotifier.removeListener(_onPortChanged);
    _controller?.removeListener(_onVideoUpdate);
    _controller?.dispose();
    _PlayerPool.remove(this);
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

    // 待机（被池子回收 / 代理未就绪）：给个明确的"点按加载"，而不是空白或转圈。
    if (_idle || _controller == null) {
      return _buildIdle();
    }

    return AspectRatio(
      aspectRatio: _videoValue?.aspectRatio ?? 16 / 9,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 视频画面（全屏期间换成黑块，避免同一个 texture 被渲染两次）
          if (_fullscreenOpen)
            const Positioned.fill(child: ColoredBox(color: Colors.black))
          else
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
              leading: const Icon(Icons.fullscreen),
              title: const Text('全屏播放'),
              onTap: () {
                Navigator.pop(ctx);
                _enterFullscreen();
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载并分享'),
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

  /// 已缓冲到的比例；缓冲完成或信息不足时返回 null（不显示这条线）。
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
          // 进度条：一根条三态——已播放（白）/ 已缓冲（半透明白）/ 未缓冲
          // （透明）。缓冲量画在滑块轨道底下，而不是另外多加一根进度条。
          _SliderWithBuffer(
            value: _videoValue?.position.inMilliseconds.toDouble() ?? 0,
            max: _videoValue?.duration.inMilliseconds.toDouble() ?? 1,
            buffered: _bufferedFraction,
            onStart: _onSeekStart,
            onEnd: (v) => _onSeekEnd(Duration(milliseconds: v.toInt())),
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

  /// 加载中占位。必须给**确定高度**：本组件挂在 ListView 的无界高度 item 里，
  /// 只写 Container(width/height: null) 会被压成 36px 的小黑块，看起来就是
  /// "没有 media"。这里用 16:9 先占位，视频初始化完成后换成真实比例。
  Widget _buildLoading() {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        width: widget.width,
        height: widget.height,
        color: Colors.black,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
            ),
            const SizedBox(height: 10),
            Text(
              _retrying ? '正在重试…' : '视频加载中…',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// 待机：被池子回收、或代理未就绪。
  ///
  /// 必须给**确定高度**（同 loading）：本组件挂在 ListView 的无界高度 item 里。
  Widget _buildIdle() {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: GestureDetector(
        onTap: () => _retryInit(),
        child: Container(
          width: widget.width,
          height: widget.height,
          color: Colors.black,
          alignment: Alignment.center,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_circle_outline, size: 40, color: Colors.white70),
              SizedBox(height: 6),
              Text('点按加载视频', style: TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError(String message) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        width: widget.width,
        height: widget.height,
        color: Colors.grey[800],
        // SingleChildScrollView 兜底：卡片高度固定，文案长短不一（解码器那条
        // 有两行），不加这个在某些字体缩放下会溢出报错。
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.movie, size: 40, color: Colors.white54),
                const SizedBox(height: 6),
                const Text(
                  '视频加载失败',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    message,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton.icon(
                      // 解码器不够用时先腾位再重试，否则重试必然同样失败。
                      onPressed: () => _retryInit(freeOthers: _lastErrorWasCodec),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('重试'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 34),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => _showErrorDetail(context),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('详情', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 技术细节弹窗：卡片上只显示"人话"，这里给全（含代理端口与原始异常），
  /// 并且可一键复制 —— 反馈时这一条比截图有用得多。
  void _showErrorDetail(BuildContext context) {
    final detail = _errorDetail ?? _error ?? '(无)';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('加载失败详情'),
        content: SizedBox(
          // 不用 double.maxFinite：Windows 端会撑成整屏宽（已知问题）。
          width: 320,
          height: 320,
          child: SingleChildScrollView(
            child: SelectableText(
              '视频: ${widget.url}\n'
              '代理端口: ${widget.proxy.port ?? '-'}\n'
              '同时存活播放器: ${_PlayerPool.liveCount}/${_PlayerPool.max}\n\n'
              '$detail',
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(ctx);
              await Clipboard.setData(ClipboardData(text: detail));
              messenger.showSnackBar(const SnackBar(
                content: Text('错误信息已复制，可粘贴到群里反馈'),
              ));
            },
            child: const Text('复制'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 视频重新初始化（错误态的「重试」、待机态的「点按加载」共用）。
  ///
  /// [freeOthers]：解码器类失败时的重试要先释放其它播放器腾出解码器，
  /// 否则重试必然以同样的错误失败 —— 用户只会得出"重试没用"。
  void _retryInit({bool freeOthers = false}) {
    if (freeOthers) _PlayerPool.freeAllExcept(this);
    // 先释放旧 controller：_initPlayer 会直接给 _controller 赋值，不先
    // dispose 就泄漏一个还在解码、还占着 texture 的播放器。
    _disposeController();
    _autoRetried = false;
    setState(() {
      _error = null;
      _errorDetail = null;
      _isLoading = true;
      _retrying = false;
      _idle = false;
    });
    _scheduleInit();
  }
}

/// 播放器池：限制**同时活着**的 ExoPlayer 数量。
///
/// 为什么必须有：Android 的硬件 AVC 解码器实例是稀缺资源（实测常见只有 2~4 个，
/// 720p60 High profile 往往只吃得下 2 个）。而详情页 `cacheExtent` 是 1800px、
/// 卡片高约 200px，一次能构建十几张卡片；**每张 `TwitterVideo` 在 initState 里
/// 就 `initialize()`**（哪怕在屏幕外、也没人按播放，只是为了显示一张静帧）。
/// 十几路 initialize 必然撞上解码器上限，报出来的正是：
///
///     MediaCodecVideoRenderer error ... format_supported=YES
///
/// —— 格式本身是支持的，只是没有空闲解码器。所以这里给存活数量设上限：
/// 超了就回收最久未用的那个，被回收的卡片回到「点按加载」待机态（不是错误态）。
class _PlayerPool {
  _PlayerPool._();

  /// 上限。AVC 硬解实例常为 2~4、720p60 High 往往只吃得下 2 个，所以留 2。
  /// 想让更多卡片保留静帧可以调大，代价是更容易撞上解码器上限。
  static const int max = 2;

  /// 队首 = 最近使用。
  static final List<_TwitterVideoState> _live = <_TwitterVideoState>[];

  static int get liveCount => _live.length;

  /// 标记为最近使用，并回收超出的。
  static void touch(_TwitterVideoState s) {
    _live.remove(s);
    _live.insert(0, s);
    _evict();
  }

  static void remove(_TwitterVideoState s) {
    _live.remove(s);
  }

  /// 手动重试前腾位：把**其它**全放掉，确保这次重试真的有空闲解码器可用。
  static void freeAllExcept(_TwitterVideoState keep) {
    final others = _live.where((e) => !identical(e, keep)).toList();
    _live
      ..clear()
      ..add(keep);
    for (final o in others) {
      o._releaseForPool();
    }
  }

  static void _evict() {
    while (_live.length > max) {
      // 优先回收没在播的；全在播就回收最久未用的（队尾）。
      final victim = _live.lastWhere(
        (e) => !e._isPlayingNow,
        orElse: () => _live.last,
      );
      _live.remove(victim);
      victim._releaseForPool();
    }
  }
}

// ─── 全屏播放 ────────────────────────────────────────────────────────────────

class _FullscreenVideo extends StatefulWidget {
  final VideoPlayerController controller;
  final String url;
  final ProxyManager proxy;
  final VoidCallback onExit;

  const _FullscreenVideo({
    required this.controller,
    required this.url,
    required this.proxy,
    required this.onExit,
  });

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo>
    with SingleTickerProviderStateMixin {
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
    // 同卡片版：代理没起来不能退回原始 URL（墙内直连必死），直接说清楚。
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
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);
      try {
        final request = await client.getUrl(uri);
        final response = await request.close();
        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }

        final tempDir = Directory.systemTemp;
        final fileName = widget.url.split('/').last.split('?').first;
        final file = File('${tempDir.path}/$fileName');
        RandomAccessFile? raf;
        try {
          final handle = await file.open(mode: FileMode.write);
          raf = handle;
          await for (final chunk in response) {
            await handle.writeFrom(chunk);
          }
          await handle.close();
          raf = null;
        } catch (_) {
          if (raf != null) {
            try {
              await raf.close();
            } catch (_) {}
          }
          await file.delete();
          rethrow;
        }

        await Share.shareXFiles(
          [XFile(file.path)],
          subject: 'Twitter Video',
        );

        if (context.mounted) {
          messenger.showSnackBar(const SnackBar(content: Text('已分享')));
        }
      } finally {
        client.close();
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
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
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
                    IconButton(
                      icon: _downloading
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
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
                    _SliderWithBuffer(
                      value: _videoValue?.position.inMilliseconds.toDouble() ?? 0,
                      max: _videoValue?.duration.inMilliseconds.toDouble() ?? 1,
                      buffered: _bufferedFraction,
                      onStart: _onSeekStart,
                      onEnd: (v) => _onSeekEnd(Duration(milliseconds: v.toInt())),
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
                        _buildSpeedButton(),
                        Text(
                          _formatDuration(widget.controller.value.duration),
                          style: const TextStyle(color: Colors.white, fontSize: 12),
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

/// 带缓冲显示的进度条：一根条上看三种状态，避免出现"两根加载条"。
///   * 白色实心 = 已播放；
///   * 半透明白 = 已缓冲（边下边播的进度）；
///   * 透明 = 还没下到。
class _SliderWithBuffer extends StatelessWidget {
  final double value;
  final double max;
  final double? buffered;
  final VoidCallback onStart;
  final ValueChanged<double> onEnd;

  const _SliderWithBuffer({
    required this.value,
    required this.max,
    required this.buffered,
    required this.onStart,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = (buffered ?? 0).clamp(0.0, 1.0);
    return Stack(
      alignment: Alignment.center,
      children: [
        if (fraction > 0)
          Padding(
            // 对齐 Slider 轨道两端的内缩（滑块半径 + 控件内边距）。
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: fraction,
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: Colors.white38,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: Colors.white,
            // 轨道下半段留空，露出底下的缓冲条。
            inactiveTrackColor: Colors.transparent,
            thumbColor: Colors.white,
            overlayColor: Colors.white24,
          ),
          child: Slider(
            value: value.clamp(0, max <= 0 ? 1 : max),
            max: max <= 0 ? 1 : max,
            onChanged: (_) => onStart(),
            onChangeEnd: onEnd,
          ),
        ),
      ],
    );
  }
}
