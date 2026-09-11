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
// 前缀导入：dart:ui 与 material 有同名导出（TextStyle / Image 等）。
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
// RenderRepaintBoundary 显式引入：抓封面要用它做类型判断。
// （material 是否转出它随版本而变，显式写出来最稳；多了最多是个 info。）
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';

import '../services/log_service.dart';
import '../services/poster_service.dart';
import '../services/proxy_manager.dart';
import '../utils/ech_url.dart';
import '../utils/video_failure.dart';

/// 加载多久之后，在 loading 卡片上多给一个「重试」按钮。
///
/// **这不是超时、更不是错误**：墙内第一次 ECH 请求要 7~11s（先 DoH 取 ECH 配置），
/// 之后还要取视频 moov、播放器自己还会重试。慢就该继续转圈等 ——
/// 0.5.3 拿 15s 当失败判据，比 0.5.2 一直等到成功还差。
///
/// 20s → **30 分钟**：这个值只影响"什么时候多出一个重试按钮"，
/// 不打断任何加载，所以设得足够长就等于"别来烦我，一直等"。
const Duration _kSlowHintAfter = Duration(minutes: 30);

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

  /// 拿到槽位已经很久还没成功 —— 只在 loading 卡片上多给一个「重试」按钮。
  ///
  /// **绝不当成错误**：墙内这一趟本来就慢（冷启动 7~11s + moov + 播放器自身重试），
  /// 曾经把它当错误直接弹"加载失败"，结果 0.5.2 会一直转圈直到成功、0.5.3 却报错。
  Timer? _slowHintTimer;
  bool _slow = false;

  /// 首次失败后自动重试一次（ECH 冷启动 7~11s、连接抖动多半是一次性的）。
  bool _autoRetried = false;

  /// 正在自动重试：loading 文案里体现，避免"卡住不动"的观感。
  bool _retrying = false;

  /// 封面（静帧）字节。**这是卡片显示画面的主要方式**：有封面就显示封面，
  /// 不占解码器；解码器只用来给"还没有封面"的卡片抓一张封面，抓完立刻让位。
  Uint8List? _poster;

  /// 抓封面用的边界（只包视频画面，不包控制栏）。
  final GlobalKey _posterKey = GlobalKey();

  /// 初始化序号：只有最新一次 init 的回调才允许改状态。
  ///
  /// 没有它，"端口变化触发 portNotifier + 父级重建触发 didUpdateWidget" 会
  /// 同时留下两个 in-flight 的 `initialize()` —— 旧的那个会写到新 controller 上，
  /// 而且**白白多吃一个解码器**（正是本次要修的资源问题）。
  int _initSeq = 0;

  /// 同一轮里多次请求初始化时合并成一次（见 [_scheduleInit]）。
  bool _initScheduled = false;

  /// 滚动监听：只用来在滚动时提醒池子"重新按可见性排一下队"。
  ScrollPosition? _scrollPosition;
  Timer? _nudgeThrottle;

  Uri _buildUrl() {
    final port = widget.proxy.port;
    // 不降级直连：墙内直连 twimg 必死（实测 000）。那样只会把一个失败换成
    // 另一个失败，还让用户看不出原因。抛出去，由上层给出可操作的提示。
    if (port == null) throw const VideoProxyNotReady();
    return EchUrl.rewriteToUri(widget.url, port);
  }

  /// 现在是否在视口内（池子分槽位时按这个排序：先给看得见的卡片抓封面）。
  bool get _visibleNow {
    if (!mounted) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final viewportH = MediaQuery.maybeOf(context)?.size.height ?? 0;
    if (viewportH <= 0) return true;
    final dy = box.localToGlobal(Offset.zero).dy;
    return dy < viewportH && dy + box.size.height > 0;
  }

  @override
  void initState() {
    super.initState();
    // 代理重启后端口会变（也可能从 null 变成有值）。没有这个监听，视频会一直
    // 停在错误态不动 —— 因为 IndexedStack/列表不会因为端口变化而重建。
    widget.proxy.portNotifier.addListener(_onPortChanged);
    // 先看有没有缓存封面：有的话卡片立刻有画面，且**一个解码器都不用占**。
    unawaited(_loadPoster());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pos = Scrollable.maybeOf(context)?.position;
    if (!identical(pos, _scrollPosition)) {
      _scrollPosition?.removeListener(_onScroll);
      _scrollPosition = pos;
      _scrollPosition?.addListener(_onScroll);
    }
  }

  /// 滚动时节流地提醒池子重排：卡片滚进视野后应当优先拿到槽位去抓封面。
  void _onScroll() {
    if (_nudgeThrottle != null) return;
    _nudgeThrottle = Timer(const Duration(milliseconds: 150), () {
      _nudgeThrottle = null;
      _PlayerPool.nudge();
    });
  }

  Future<void> _loadPoster() async {
    if (_poster != null) return;
    final bytes = await PosterService.load(widget.url);
    if (!mounted) return;
    if (bytes != null) {
      // 有缓存封面：立刻有画面，**一个解码器都不用占**（回看时是秒出的）。
      setState(() {
        _poster = bytes;
        _isLoading = false;
      });
      return;
    }
    // 没缓存：申请一个槽位去抓一张。排队期间显示 loading 转圈。
    _requestSlot();
  }

  @override
  void didUpdateWidget(TwitterVideo old) {
    super.didUpdateWidget(old);
    if (old.proxy != widget.proxy) {
      old.proxy.portNotifier.removeListener(_onPortChanged);
      widget.proxy.portNotifier.addListener(_onPortChanged);
    }
    if (old.url != widget.url || old.proxy.port != widget.proxy.port) {
      _PlayerPool.release(this);
      _disposeController();
      _videoValue = null;
      _error = null;
      _isLoading = true;
      _showControls = true;
      _hideTimer?.cancel();
      _isDragging = false;
      _autoRetried = false;
      // 只有换了视频才丢封面：封面按视频 URL 缓存，代理换端口不影响内容。
      if (old.url != widget.url) {
        _poster = null;
        unawaited(_loadPoster());
      } else {
        _requestSlot();
      }
    }
  }

  /// 代理端口出现/变化时自动重试一次：端口变化意味着代理刚起来或刚重启，
  /// 之前那次失败已经过期了。
  void _onPortChanged() {
    if (!mounted) return;
    if (widget.proxy.port == null) return;
    if (_error == null && !_needsSlot) return;
    _autoRetried = false;
    _retryInit();
  }

  /// 还没有封面 = 需要用解码器去抓一张。
  bool get _needsSlot => _poster == null;

  /// 申请一个解码器槽位。
  ///
  /// [userInitiated]：用户明确要播这张（点了封面上的播放键）。
  /// 自动路径只服务"还没有封面"的卡片 —— 有封面的卡片不该白占解码器；
  /// 但用户点播时必须给，否则点了没反应。
  void _requestSlot({bool userInitiated = false}) {
    if (!mounted) return;
    if (!userInitiated && !_needsSlot) return;
    // 有封面时保持封面显示（初始化完成后无缝换成画面），不要闪一下转圈。
    if (_needsSlot && !_isLoading) {
      setState(() => _isLoading = true);
    }
    _PlayerPool.request(this);
  }

  /// 池子把槽位给了我们：真正开始初始化（并发上限由池子保证）。
  void _onSlotGranted() {
    if (!mounted || _controller != null) return;
    unawaited(_initPlayer());
  }

  /// 合并同一轮内的多次请求（初始构建、端口变化、重试可能叠在一起）。
  void _scheduleInit() {
    if (_initScheduled) return;
    _initScheduled = true;
    scheduleMicrotask(() {
      _initScheduled = false;
      if (!mounted) return;
      _requestSlot();
    });
  }

  Future<void> _initPlayer() async {
    final seq = ++_initSeq;
    _slowHintTimer?.cancel();
    _slow = false;
    // 慢 ≠ 错：只是过一会儿多给一个「重试」出口，**绝不切错误态**。
    // （0.5.3 把 15s 无响应直接判成"加载失败"，墙内冷启动本来就 7~11s，
    //   结果比 0.5.2 一直转圈等到成功还差。）
    _slowHintTimer = Timer(_kSlowHintAfter, () {
      if (!mounted || seq != _initSeq || !_isLoading) return;
      setState(() => _slow = true);
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

      _slowHintTimer?.cancel();
      controller.addListener(_onVideoUpdate);
      controller.setLooping(false);

      setState(() {
        _isLoading = false;
        _retrying = false;
        _slow = false;
        _error = null;
          _videoValue = controller.value;
      });
      // 抓一张封面：抓到就交还槽位（见 _capturePoster），所以解码器占用是暂时的。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_capturePoster());
      });
    } catch (e, st) {
      if (!mounted || seq != _initSeq) return;
      _slowHintTimer?.cancel();
      _logFailure(e, st);

      // 自动重试一次：冷启动（新进程首次 ECH 要 7~11s）与连接抖动多为一次性。
      if (!_autoRetried) {
        _autoRetried = true;
        setState(() => _retrying = true);
        await Future.delayed(_kAutoRetryDelay);
        if (!mounted || seq != _initSeq) return;
        _disposeController();
        _scheduleInit();
        return;
      }

      // 失败就把槽位还回去，别占着解码器不放。
      _PlayerPool.release(this);
      _fail('$e');
    }
  }

  /// 统一的失败落点。message 就是**具体错误原文**（不加工）。
  void _fail(String message) {
    _slowHintTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _error = message;
      _isLoading = false;
      _retrying = false;
      _slow = false;
    });
  }

  /// 原始错误里带着 ExoPlayer 的 Format（编码/分辨率/帧率）与
  /// `format_supported`，是区分"解码器不够"和"网络失败"的唯一线索，
  /// 必须原样留下来 —— 否则报告里只剩一句"加载失败"。
  void _logFailure(Object e, StackTrace st) {
    LogService.recordError(
      'video.init',
      'url=${widget.url}\n'
      'proxyPort=${widget.proxy.port ?? '-'}\n'
      '分类: ${VideoFailure.humanize(e)}\n'
      '$e',
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
        // 卡片上显示原文；分类只写进日志（反馈包需要一眼看出是解码器还是网络）。
        _error = desc;
        LogService.recordError(
          'player',
          '分类: ${VideoFailure.humanize(desc)}\n$desc',
        );
      }
    });
  }

  void _togglePlay() {
    if (_controller == null) return;
    // 用户在用的这个不许被池子收走。
    _PlayerPool.markPlaying(this);
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
  }

  /// 只释放 controller，**不碰池子**（池子的登记/交还由调用方显式做，
  /// 免得"释放 controller"和"交还槽位"两件事被混在一起导致槽位泄漏）。
  void _disposeController() {
    // 作废在飞的初始化：它的回调即使回来也不许再改状态。
    _initSeq++;
    _slowHintTimer?.cancel();
    final old = _controller;
    _controller = null;
    // 快照一起清掉：build 用 `_videoValue != null` 判断"可以渲染真画面"，
    // 留着旧值会去渲染一个已经释放的 controller。
    _videoValue = null;
    if (old != null) {
      old.removeListener(_onVideoUpdate);
      unawaited(old.dispose());
    }
  }

  /// 池子把槽位收走时调用（抢位给更该拿的卡片）：交还解码器。
  ///
  /// 有封面就显示封面；没有就继续排队等下一次（loading），**不落错误态** ——
  /// 主动让位不是失败。
  void _releaseForPool() {
    _disposeController();
    if (!mounted) return;
    setState(() {
      _videoValue = null;
      _retrying = false;
      _error = null;
      _isLoading = _needsSlot;
      _slow = false;
    });
    _PlayerPool.request(this);
  }

  bool get _isPlayingNow => _controller?.value.isPlaying ?? false;

  bool get _hasPoster => _poster != null;

  /// 抓到封面且没在播：交还槽位，改用封面显示（不占解码器）。
  ///
  /// 这是整套设计的核心 —— 槽位因此会被"用一下就让出去"，一张一张地把封面铺满
  /// 整个列表，而同时占用的解码器始终不超过 _PlayerPool.max。
  void _becomePosterOnly() {
    if (!mounted || _isPlayingNow || _fullscreenOpen) return;
    // 抓帧不可用时槽位没有意义（没有"换出来"的东西），留着播放器显示画面更有用。
    if (_PlayerPool.captureUnavailable) return;
    _PlayerPool.release(this);
    _disposeController();
    setState(() {
      _videoValue = null;
      _isLoading = false;
      _slow = false;
      _showControls = false;
    });
  }

  /// 抓当前帧当封面。
  ///
  /// 用抓屏（`RepaintBoundary.toImage`）而**不是** video_thumbnail：后者走
  /// MediaMetadataRetriever，自己也要占一个解码器，会在播放器池已经占满时把
  /// 并发解码数顶到 3 —— 正是要避免的事。抓屏不占解码器。
  ///
  /// 代价：`Texture` 能不能被抓进离屏图像跟平台/时序有关，抓不到会是**整片黑**。
  /// 黑封面比「点按加载」占位更糟（用户会以为视频本身是黑的），所以这里做黑帧
  /// 检查：黑就等一会儿重试，最多 3 次，最后仍失败就干脆不写缓存。
  Future<void> _capturePoster({int attempt = 1}) async {
    if (!mounted || _controller == null || _poster != null) return;
    if (PosterService.memory(widget.url) != null) return;
    final boundary = _posterKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return;
    // 尺寸太小说明布局还没稳定（或卡片已被回收）。
    if (boundary.size.width < 16 || boundary.size.height < 16) return;

    Uint8List? png;
    try {
      final image = await boundary.toImage(pixelRatio: 1.0);
      try {
        final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (raw == null ||
            _mostlyBlack(
                raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes))) {
          if (attempt < 3) {
            await Future.delayed(const Duration(milliseconds: 700));
            if (mounted) await _capturePoster(attempt: attempt + 1);
          } else {
            // 三次都抓不到（多半是 Texture 没被合成进离屏图像）：兜底。
            _giveUpCapture();
          }
          return;
        }
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        png = data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } catch (e) {
      debugPrint('capture poster failed: $e');
      _giveUpCapture();
      return;
    }
    if (png == null || png.isEmpty || !mounted) {
      _giveUpCapture();
      return;
    }
    setState(() => _poster = png);
    await PosterService.put(widget.url, png);
    // 封面到手，交还解码器（除非用户正在这一张上播放）。
    _becomePosterOnly();
  }

  /// 抓不到封面（Texture 没进离屏图像 / 编码失败）。
  ///
  /// **必须兜底**：整套设计的前提是"封面能把解码器换出来"，一旦抓不到，
  /// 压着并发就等于让后面所有卡片永远排队转圈 —— 比 0.5.2（每张都开播放器）
  /// 还惨。所以这里直接标记"抓帧不可用"，池子从此不再限制并发，
  /// 退化成 0.5.2 的行为：每张卡片都有自己的播放器、都有自己的画面。
  void _giveUpCapture() {
    _PlayerPool.noteCaptureUnavailable();
  }

  /// 抽样判断整帧是否接近全黑（亮像素占比 < 2%）。
  /// 抽样用质数步长，避免和行宽共振后永远只采到同一列。
  static bool _mostlyBlack(Uint8List bytes) {
    const step = 53;
    var sampled = 0;
    var lit = 0;
    for (var i = 0; i + 3 < bytes.length; i += 4 * step) {
      sampled++;
      final luma =
          (bytes[i] * 299 + bytes[i + 1] * 587 + bytes[i + 2] * 114) ~/ 1000;
      if (luma > 12) lit++;
    }
    return sampled == 0 || lit * 50 < sampled;
  }

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
    _slowHintTimer?.cancel();
    _nudgeThrottle?.cancel();
    _scrollPosition?.removeListener(_onScroll);
    widget.proxy.portNotifier.removeListener(_onPortChanged);
    _controller?.removeListener(_onVideoUpdate);
    _controller?.dispose();
    // 槽位必须还回去，否则池子会以为它还被占着，后面所有卡片都排不上队。
    _PlayerPool.release(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _buildError(_error!);
    }

    // 播放器就绪（initialize 完成）→ 真画面。
    // 注意判据是 `_videoValue != null` 而**不是** `_controller != null`：
    // 初始化途中 controller 已经建好但还不能渲染，拿它去建 VideoPlayer 会渲染
    // 一个未初始化的 texture。
    final value = _videoValue;
    if (_controller != null && value != null) {
      return _buildPlayer(value);
    }

    // 还没就绪：有封面就先显示封面（秒出、不占解码器），否则转圈等。
    final poster = _poster;
    if (poster != null) {
      return _buildPoster(poster);
    }
    return _buildLoading();
  }

  Widget _buildPlayer(VideoPlayerValue value) {

    return AspectRatio(
      aspectRatio: value.aspectRatio,
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
              // RepaintBoundary：抓封面时只抓视频画面（不含控制栏）。
              child: RepaintBoundary(
                key: _posterKey,
                child: VideoPlayer(_controller!),
              ),
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
            // 慢才出现的重试入口同样放最前（与错误卡片一致）。
            if (_slow) ...[
              TextButton(
                onPressed: () => _retryInit(),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('重试', style: TextStyle(fontSize: 12, color: Colors.white70)),
              ),
              const SizedBox(height: 6),
            ],
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

  /// 封面态：显示已缓存的静帧，点一下才去占解码器播放。
  ///
  /// 必须给**确定高度**（同 loading）：本组件挂在 ListView 的无界高度 item 里。
  Widget _buildPoster(Uint8List poster) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: GestureDetector(
        onTap: () => _retryInit(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(
              poster,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // 封面坏了不该让整张卡片炸掉。
              errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
            ),
            const Center(
              child: Icon(Icons.play_circle_outline, size: 44, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  /// 错误卡片（0.5.2 的形态）：**重试按钮放最前**，下面原样显示具体错误。
  ///
  /// 为什么不显示概括文案：概括会丢掉唯一能定位问题的东西。用户实测报错是
  /// ```
  /// PlatformException(VideoError, ... MediaCodecVideoRenderer error, index=0,
  /// format=Format(..., video/avc, avc1.640020, 1891376, und, [1280, 720, 60.0, ...]),
  /// format_supported=YES, null, null)
  /// ```
  /// —— 这串字里带着编码/分辨率/帧率/`format_supported`，"解码器不够用"还是
  /// "网络失败"一眼就能分开。换成一句"视频加载失败"就全丢了。
  ///
  /// 按钮在前还有个实际原因：具体错误动辄 5~10 行，卡片只有 16:9 高，
  /// 按钮放下面会被挤出可视区。
  Widget _buildError(String message) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        width: widget.width,
        height: widget.height,
        color: Colors.grey[800],
        // 兜底滚动：错误文本很长时不能溢出（卡片高度是固定的 16:9）。
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton.icon(
                  // 重试会还掉自己的槽位再重新排队；池子按"可见优先"重新分配，
                  // 看得见的那张能挤掉看不见的占位者。
                  onPressed: () => _retryInit(),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重试'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(height: 8),
                // SelectableText：长按可选中复制（0.5.2 就是这个行为），
                // 反馈时比截图有用。
                SelectableText(
                  message,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 重新申请一次解码器（错误态的「重试」、封面态/loading 的「点按/重试」共用）。
  void _retryInit() {
    // 先把自己占的槽位还掉再重新申请：池子重新分槽时会考虑可见性，这样"用户正在
    // 看/刚点的那张"能排到前面去（可见的卡片可以挤掉看不见的占位者）。
    _PlayerPool.release(this);
    _disposeController();
    _autoRetried = false;
    setState(() {
      _error = null;
      _isLoading = _needsSlot;
      _retrying = false;
      _slow = false;
    });
    _requestSlot(userInitiated: true);
  }
}

/// 解码器池：同时占用**解码器**的卡片数上限。
///
/// 为什么需要：Android 的硬件 AVC 解码器实例是稀缺资源（常见只有 2~4 个，
/// 720p60 High profile 往往只吃得下 2 个），而详情页 `cacheExtent` 是 1800px、
/// 卡片高约 200px，一次能构建十几张卡片。十几路 `initialize()` 必然撞上限，
/// 报出来的就是 `MediaCodecVideoRenderer error ... format_supported=YES`。
///
/// 但**不能因此让卡片没有画面**（0.5.3 的教训：把槽位压到 2 之后，其余卡片变成
/// 「点按加载」占位，比 0.5.2 还难用）。所以这里的策略是"用一下就还"：
///
///   1. 槽位只用来给**还没有封面**的卡片抓一张封面（`RepaintBoundary.toImage`）；
///   2. 抓到封面立刻交还，改由封面显示（`_becomePosterOnly`），不占解码器；
///   3. 于是槽位会一张一张地把封面铺满整个列表，同时占用的解码器始终 ≤ max；
///   4. 分槽按**可见性优先**：排队者里看得见的先拿，槽位被看不见的卡片占着时
///      可以把那个占位者收回来（`_pickVictim`）—— 用户正在看的那张不用等。
///
/// 排队期间卡片显示 loading 转圈（和 0.5.2 一样），**没有**「点按加载」占位。
class _PlayerPool {
  _PlayerPool._();

  /// 上限。AVC 硬解实例常为 2~4、720p60 High 往往只吃得下 2 个，所以留 2。
  static const int max = 2;

  /// 已占槽的（含正在 initialize 的 —— 解码器是在 prepare 阶段就申请的，
  /// 所以必须把 in-flight 也算进来，否则并发数会失控）。
  static final List<_TwitterVideoState> _live = <_TwitterVideoState>[];

  /// 排队的。
  static final List<_TwitterVideoState> _waiting = <_TwitterVideoState>[];

  /// 抓帧不可用（真机上 `RepaintBoundary.toImage` 抓不到 Texture）。
  ///
  /// 一旦确认不可用就**不再限制并发**：封面只能来自活着的播放器，
  /// 压着并发等于让卡片没有画面 —— 那比 0.5.2 还差。
  static bool captureUnavailable = false;

  static void noteCaptureUnavailable() {
    if (captureUnavailable) return;
    captureUnavailable = true;
    // 已经在排队的全部放行，让每张卡片都能拿到自己的播放器。
    pump();
  }

  /// pump 期间只允许入队，不许直接发槽位。
  ///
  /// 否则：抢位时把占位者 evict → 它 `_releaseForPool()` 里立刻重新 request →
  /// 此时槽位正好空着 → 它又把自己要回去了，抢位等于白做（死循环）。
  static bool _pumping = false;

  static int get liveCount => _live.length;
  static int get waitingCount => _waiting.length;

  /// 申请槽位：有空位立刻给，否则排队。
  static bool request(_TwitterVideoState s) {
    if (_live.contains(s)) return true;
    if (_waiting.contains(s)) {
      if (!_pumping) pump();
      return false;
    }
    if (!_pumping && (captureUnavailable || _live.length < max)) {
      _live.add(s);
      s._onSlotGranted();
      return true;
    }
    _waiting.add(s);
    if (!_pumping) pump();
    return false;
  }

  /// 交还槽位（抓到封面、失败、被回收、dispose 都走这里）。
  static void release(_TwitterVideoState s) {
    _live.remove(s);
    _waiting.remove(s);
    if (!_pumping) pump();
  }

  /// 标记为"正在使用"：正在播的卡片短期内在队首（但不影响能否被抢位，
  /// 抢位不碰正在播的，见 _pickVictim）。
  static void markPlaying(_TwitterVideoState s) {
    _live.remove(s);
    _live.insert(0, s);
  }

  /// 滚动时提醒池子重排（可见性变了）。
  static void nudge() => pump();

  /// 分槽位：可见优先；槽位被看不见的卡片占着时，收回给看得见的排队者。
  static void pump() {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_waiting.isNotEmpty) {
        final waiter = _pickWaiter();
        if (waiter == null) return;
        if (captureUnavailable || _live.length < max) {
          _waiting.remove(waiter);
          _live.add(waiter);
          waiter._onSlotGranted();
          continue;
        }
        // 满了：只有"排队者可见 + 找得到看不见且没在播的占位者"才抢位。
        if (!waiter._visibleNow) return;
        final victim = _pickVictim();
        if (victim == null) return;
        _live.remove(victim);
        _waiting.remove(waiter);
        _live.add(waiter);
        victim._releaseForPool();
        waiter._onSlotGranted();
        // 一次只处理一个抢位，剩下的等下一轮（避免同时把好几张卡打回排队）。
        return;
      }
    } finally {
      _pumping = false;
    }
  }

  /// 挑一个排队者：先找看得见的；都没有就给最早排队的。
  static _TwitterVideoState? _pickWaiter() {
    if (_waiting.isEmpty) return null;
    for (final w in _waiting) {
      if (w._visibleNow) return w;
    }
    return _waiting.first;
  }

  /// 抢位时的牺牲者：看不见 + 没在播；其中**已经有封面**的优先
  /// （收回去之后它照样有画面，观感无损）。
  static _TwitterVideoState? _pickVictim() {
    for (final e in _live) {
      if (!e._visibleNow && !e._isPlayingNow && e._hasPoster) return e;
    }
    for (final e in _live) {
      if (!e._visibleNow && !e._isPlayingNow) return e;
    }
    return null;
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
