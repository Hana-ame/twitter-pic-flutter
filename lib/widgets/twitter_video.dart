// twitter_video.dart
// 视频卡片：通过本机 ECH 代理加载，支持流式播放、下载、分享。
//
// 分层（v0.5.13 拆封装后）：
//   * 并发/分槽策略 → lib/video/video_decoder_pool.dart（本文件只实现它的
//     [DecoderSlotUser] 接口）；
//   * 失败分类与上限语义 → lib/video/decoder_policy.dart（fork 开了软解回退，
//     "codec 报错=并发撞顶"的旧信号已经不存在了，别在本文件里重新发明重试）；
//   * 全屏页 / 进度条 → lib/widgets/video/ 下的共用组件；
//   * 本文件只剩：一张卡片的生命周期状态机 + 控制栏 UI。
//
// 与旧版 (v0.2.8) 的差异：删除手动流式落盘 / spool / isolate，直接用
// `VideoPlayerController.networkUrl(EchUrl.rewrite(...))`，video_player 内部
// 缓冲、边下边播；控制栏逻辑保留（自动淡出、拖动进度、全屏），新增下载、分享。

import 'dart:async';
// Uint8List：封面字节/抓帧缓冲。以前这个类型是跟着 `dart:io` 顺带进来的，
// 下载逻辑拆到 services/video_downloader.dart 后必须自己显式导入。
import 'dart:typed_data';
// 前缀导入：dart:ui 与 material 有同名导出（TextStyle / Image 等）。
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
// RenderRepaintBoundary 显式引入：抓封面要用它做类型判断。
// （material 是否转出它随版本而变，显式写出来最稳；多了最多是个 info。）
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../services/log_service.dart';
import '../services/poster_service.dart';
import '../services/proxy_manager.dart';
import '../services/video_downloader.dart';
import '../utils/ech_url.dart';
import '../utils/frame_luma.dart';
import '../utils/video_failure.dart';
import '../video/decoder_policy.dart';
import '../video/video_decoder_pool.dart';
import 'video/fullscreen_video.dart';
import 'video/video_slider_with_buffer.dart';

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
    implements DecoderSlotUser {
  /// 全局解码器槽位池（上限/分槽/抢占逻辑见 video/video_decoder_pool.dart）。
  static final VideoDecoderPool _pool = VideoDecoderPool.shared;

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

  /// 拿到槽位的时刻：用来量"槽位被占多久"（见 _capturePoster）。
  Stopwatch? _slotHeldSince;

  /// 用户点了封面/重试：拿到播放器后直接开始播（点一下就能看，不用再点播放键）。
  bool _autoPlayOnReady = false;

  /// 这张卡片是**用户点播**的：不许把它的播放器交给池子。
  ///
  /// 必要性（第二个"点不动"的成因）：没有封面时点播 → 初始化成功、开始播放 →
  /// 抓封面在下一帧（~16ms）就完成，此刻 `value.isPlaying` 可能还没翻转 →
  /// `_becomePosterOnly` 判定"没在播"把播放器还回去 → **正在起播的视频当场死掉**。
  bool _userInitiated = false;

  /// 抓封面用的边界（只包视频画面，不包控制栏）。
  final GlobalKey _posterKey = GlobalKey();

  /// "封面抓帧成功"整轮只记一条日志（每个视频都记会把反馈包刷满）。
  static bool _captureLogged = false;

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

  // ─── DecoderSlotUser：池子看卡片的唯一入口 ────────────────────────────────

  @override
  bool get slotMounted => mounted;

  /// 还没有封面 = 需要用解码器去抓一张。
  @override
  bool get slotNeedsPoster => _poster == null;

  /// 现在是否在视口内（池子按这个排序：先给看得见的卡片抓封面）。
  @override
  bool get slotVisibleNow {
    if (!mounted) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final viewportH = MediaQuery.maybeOf(context)?.size.height ?? 0;
    if (viewportH <= 0) return true;
    final dy = box.localToGlobal(Offset.zero).dy;
    return dy < viewportH && dy + box.size.height > 0;
  }

  @override
  bool get slotIsPlaying => _controller?.value.isPlaying ?? false;

  @override
  bool get slotHasPoster => _poster != null;

  @override
  void onSlotGranted() {
    if (!mounted || _controller != null) return;
    unawaited(_initPlayer());
  }

  /// 池子把槽位收走时调用（抢位给更该拿的卡片）：交还解码器。
  ///
  /// 有封面就显示封面；没有就继续排队等下一次（loading），**不落错误态** ——
  /// 主动让位不是失败。
  @override
  void onSlotRevoked() {
    _userInitiated = false;
    _disposeController();
    if (!mounted) return;
    setState(() {
      _videoValue = null;
      _retrying = false;
      _error = null;
      _isLoading = slotNeedsPoster;
      _slow = false;
    });
    _pool.request(this);
  }

  // ─── 生命周期 ─────────────────────────────────────────────────────────────

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
      _pool.nudge();
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
      _pool.release(this);
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
    // 有错误（端口变化让它过期了）或者还缺封面（重新排队）才需要动作；
    // 已就绪且没错误就什么都不做。
    if (_error == null && !slotNeedsPoster) return;
    _autoRetried = false;
    _retryInit();
  }

  /// 申请一个解码器槽位。
  ///
  /// [userInitiated]：用户明确要播这张（点了封面上的播放键）。
  /// 自动路径只服务"还没有封面"的卡片 —— 有封面的卡片不该白占解码器；
  /// 但用户点播时必须给，否则点了没反应。
  void _requestSlot({bool userInitiated = false}) {
    if (!mounted) return;
    if (!userInitiated && !slotNeedsPoster) return;
    // 有封面时保持封面显示（初始化完成后无缝换成画面），不要闪一下转圈。
    if (slotNeedsPoster && !_isLoading) {
      setState(() => _isLoading = true);
    }
    _pool.request(this, urgent: userInitiated);
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
    _slotHeldSince = Stopwatch()..start();
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
      if (_autoPlayOnReady) {
        _autoPlayOnReady = false;
        // 正在播的不许被抢走槽位。
        _pool.markPlaying(this);
        unawaited(controller.play().catchError((Object e, StackTrace st) {
          LogService.recordError('play', e, st);
        }));
        setState(() => _showControls = true);
        _scheduleHideControls();
      }
      // 抓一张封面：抓到就交还槽位（见 _capturePoster），所以解码器占用是暂时的。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_capturePoster());
      });
    } catch (e, st) {
      if (!mounted || seq != _initSeq) return;
      _slowHintTimer?.cancel();
      _logFailure(e, st);

      // 失败怎么处理**只问 policy**（lib/video/decoder_policy.dart）：
      // fork 开了软解回退之后，"硬解实例被占满"这种并发信号已经在 media3 内部
      // 消化掉了，报上来的 codec 类错误 = 硬解软解都不行 = 重排也救不了。
      // 所以这里不再"降档重排最多 3 次"（每次重排都是在墙内慢链路上重烧一遍
      // moov 下载），只剩一次性网络抖动值得自动重试。
      final action = _pool.policy.classify(e);
      if (action == DecodeFailureAction.retryOnce && !_autoRetried) {
        _autoRetried = true;
        // 必须先把槽位还回去再重试：不还给 _pool.request() 看到自己还在 _live 里
        // 会直接短路，重试静默变 no-op（卡片卡在转圈且没有重试入口）。
        _pool.release(this);
        setState(() => _retrying = true);
        await Future.delayed(_kAutoRetryDelay);
        // seq 检查必须在 _disposeController() **之前**：后者会 _initSeq++，
        // 放后面这个分支就永远 return，重试是死代码。
        if (!mounted || seq != _initSeq) return;
        _disposeController();
        _scheduleInit();
        return;
      }

      // 失败就把槽位还回去，别占着解码器不放。
      _pool.release(this);
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
    _pool.markPlaying(this);
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

  /// 抓到封面且没在播：交还槽位，改用封面显示（不占解码器）。
  ///
  /// 这是整套设计的核心 —— 槽位因此会被"用一下就让出去"，一张一张地把封面铺满
  /// 整个列表，而同时占用的解码器始终不超过池子上限。
  void _becomePosterOnly() {
    if (!mounted || slotIsPlaying || _fullscreenOpen) return;
    // 用户点播的那张不许交还（见 _userInitiated 的注释）。
    if (_userInitiated) return;
    // 抓帧不可用时槽位没有意义（没有"换出来"的东西），留着播放器显示画面更有用。
    if (_pool.captureUnavailable) return;
    _pool.release(this);
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
  /// 并发解码数顶上去 —— 正是要避免的事。抓屏不占解码器。
  ///
  /// 代价：`Texture` 能不能被抓进离屏图像跟平台/时序有关，抓不到会是**整片黑**。
  /// 黑封面比「点按加载」占位更糟（用户会以为视频本身是黑的），所以这里用
  /// `isMostlyBlack`（utils/frame_luma.dart）做黑帧检查：黑就等一会儿重试，
  /// 最多 3 次，最后仍失败就干脆不写缓存。
  Future<void> _capturePoster({int attempt = 1}) async {
    if (!mounted || _controller == null || _poster != null) return;
    final captureWatch = Stopwatch()..start();
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
            isMostlyBlack(
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
    captureWatch.stop();
    setState(() => _poster = png);
    // 上报一次成功：连续成功说明本机还吃得下，可以谨慎上调并发。
    _pool.noteSuccess();
    // 量一下槽位到底被占了多久、其中抓帧占多少 —— "抓封面是不是白占着解码器"
    // 这个问题只能靠数据回答（init 是网络耗时，抓帧是渲染操作，两者差一个量级）。
    _pool.noteSlotHold(
      initMs: _slotHeldSince?.elapsedMilliseconds,
      captureMs: captureWatch.elapsedMilliseconds,
    );
    // 槽位立刻还掉：帧已经在手上了，后面的写盘不需要解码器。
    // （曾经这里还有一次重复调用 —— 幂等但读起来像漏掉了什么，删了。）
    _becomePosterOnly();
    await PosterService.put(widget.url, png);
    if (!_captureLogged) {
      _captureLogged = true;
      LogService.recordNote('poster', '封面抓帧成功（走缓存路径，解码器用完即还）');
    }
  }

  /// 抓不到封面（Texture 没进离屏图像 / 编码失败）。
  ///
  /// **必须兜底**：整套设计的前提是"封面能把解码器换出来"，一旦抓不到，
  /// 压着并发就等于让后面所有卡片永远排队转圈 —— 比不设池子还惨。所以这里
  /// 直接标记"抓帧不可用"，池子从此不再限制并发，退回每张卡片都持有自己
  /// 播放器的行为。
  void _giveUpCapture() {
    if (_pool.captureUnavailable) return;
    LogService.recordNote(
      'poster',
      '抓帧不可用（整片黑或异常）：已停止限制并发，退回"每张卡片各自持有播放器"'
      '（v0.5.2 行为）。url=${widget.url}',
    );
    _pool.noteCaptureUnavailable();
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
        builder: (_) => FullscreenVideo(
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
    // RandomAccessFile 同时写会损坏。
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
    final uri = EchUrl.rewriteToUri(widget.url, proxyPort);

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在下载视频...')));

    try {
      final file = await VideoDownloader.fetchToTemp(uri: uri, url: widget.url);
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
    _pool.release(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      final msg = _error!;
      // 该不该给重试按钮**也只问 policy**：fork 之后报上来的解码类错误意味着
      // 软硬解都不行，按钮只会诱导用户反复点一个必然失败的动作。错误原文照留
      // ——反馈定位靠的就是那串编码/分辨率/帧率。
      final retryable =
          _pool.policy.classify(msg) == DecodeFailureAction.retryOnce;
      return _buildError(msg, retryable: retryable);
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
                child: const Icon(Icons.play_arrow,
                    size: 40, color: Colors.white),
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
              child:
                  Text('视频操作', style: TextStyle(fontWeight: FontWeight.bold)),
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
          VideoSliderWithBuffer(
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
                    ? Icons.pause
                    : Icons.play_arrow),
                onPressed: _togglePlay,
                color: Colors.white,
                iconSize: 32,
              ),
              Text(
                _isDragging
                    ? _formatDuration(Duration(
                        milliseconds: (_controller!.value.position.inMilliseconds +
                                (_videoValue?.duration.inMilliseconds ?? 1) ~/
                                    2)))
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
                icon: const Icon(Icons.download,
                    color: Colors.white, size: 24),
                onPressed: _downloadVideo,
                iconSize: 24,
              ),
              IconButton(
                icon: const Icon(Icons.fullscreen,
                    color: Colors.white, size: 24),
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
    // 排队等槽位时点一下 = "我要这张，先给我"（走 userInitiated 抢位）。
    // **已经在初始化中的不响应点击**：否则用户多点几下就把下载反复打断重来，
    // 在墙内这条慢链路上等于永远加载不完。
    final queued = _pool.isWaiting(this);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: GestureDetector(
        onTap: queued ? () => _retryInit(autoPlay: true) : null,
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
                  onPressed: () => _retryInit(autoPlay: true),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('重试',
                      style: TextStyle(fontSize: 12, color: Colors.white70)),
                ),
                const SizedBox(height: 6),
              ],
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.white),
              ),
              const SizedBox(height: 10),
              Text(
                _retrying ? '正在重试…' : '视频加载中…',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
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
        // 点封面 = 我要看这个视频：加载 + 自动播放。
        onTap: () => _retryInit(autoPlay: true),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(
              poster,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // 封面坏了不该让整张卡片炸掉。
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: Colors.black),
            ),
            // 点了封面之后正在初始化：给个转圈反馈，否则用户以为"点了没反应"。
            if (_controller != null && _videoValue == null)
              const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: Colors.white),
                ),
              )
            else
              const Center(
                child: Icon(Icons.play_circle_outline,
                    size: 44, color: Colors.white70),
              ),
          ],
        ),
      ),
    );
  }

  /// 错误卡片：**重试按钮放最前**（可选），下面原样显示具体错误。
  ///
  /// 为什么不显示概括文案：概括会丢掉唯一能定位问题的东西。用户实测报错是
  /// ```
  /// PlatformException(VideoError, ... MediaCodecVideoRenderer error, index=0,
  /// format=Format(..., video/avc, avc1.640020, 1891376, und, [1280, 720, 60.0, ...]),
  /// format_supported=YES, null, null)
  /// ```
  /// —— 编码/分辨率/帧率/`format_supported` 全在里面，"解码器不行"还是
  /// "网络失败"一眼分开。换成一句"视频加载失败"就全丢了。
  ///
  /// 按钮在前还有个实际原因：具体错误动辄 5~10 行，卡片只有 16:9 高，
  /// 按钮放下面会被挤出可视区。
  ///
  /// [retryable] 为 false 时**不显示重试按钮**（判定见 decoder_policy.dart）。
  Widget _buildError(String message, {bool retryable = true}) {
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
                if (retryable) ...[
                  ElevatedButton.icon(
                    // 重试 = 用户就是要看这个视频：抢到槽位后直接播。
                    onPressed: () => _retryInit(autoPlay: true),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
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
  void _retryInit({bool autoPlay = false}) {
    _autoPlayOnReady = autoPlay;
    if (autoPlay) _userInitiated = true;
    // 先把自己占的槽位还掉再重新申请：池子按"用户点播 > 可见 > 排队顺序"分槽，
    // 所以刚点的那张必定拿得到。
    _pool.release(this);
    _disposeController();
    _autoRetried = false;
    setState(() {
      _error = null;
      _isLoading = slotNeedsPoster;
      _retrying = false;
      _slow = false;
    });
    _requestSlot(userInitiated: true);
  }
}
