// video_decoder_pool.dart
// 解码器槽位池：同时占用**解码器**的卡片数上限 + 按可见性分槽。
//
// 从 twitter_video.dart 的私有 `_PlayerPool` 抽出来，为的是能单测：分槽、
// 抢占、pump 重入保护这些分支全靠真机时序才能触发，以前根本测不到。
// 池子只通过 [DecoderSlotUser] 接口看卡片，不碰 widget 的私有成员。
//
// 设计要点（与 twitter_video.dart 的封面策略配套）：
//   1. 槽位只用来给**还没有封面**的卡片抓一张封面（RepaintBoundary.toImage）；
//   2. 抓到封面立刻交还，改由封面显示，不占解码器；
//   3. 槽位一张一张把封面铺满列表，同时占用 ≤ max（上限语义见
//      ../video/decoder_policy.dart —— fork 开了软解回退，上限从"防撞硬解报错"
//      变成"约束解码 CPU 负载"）；
//   4. 分槽**可见优先**；用户点播**直接清场**（见 pump）—— 硬解实例全机共享，
//      抢不到就是软解，不是"慢一点"；
//   5. **谁在播谁拿硬解**：正在播的那张一旦换人，前一张就地让位（[claimPlayback]），
//      回头再播它时会重新初始化并 seek 回原位（twitter_video.dart）。
//
// Android 的硬件 AVC 解码器实例是稀缺资源（常见 2~4 个），而详情页
// `cacheExtent` 1800px、卡片约 200px，一次构建十几张卡片 —— 不设上限必然打架。

import '../services/log_service.dart';
import '../services/storage_service.dart';
import '../utils/decode_budget.dart';
import 'decoder_policy.dart';
import 'video_compat_mode.dart';

/// 池子眼里的"一张卡片"。实现在 [TwitterVideo] 的 State 上。
abstract class DecoderSlotUser {
  /// widget 还挂在树上吗（池子可能持有刚 dispose 的引用一个 microtask）。
  bool get slotMounted;

  /// 还需要槽位吗 = 还没有封面。
  bool get slotNeedsPoster;

  /// 现在是否在视口内（分槽优先级）。
  bool get slotVisibleNow;

  /// 正在播放吗（抢占时的保护对象 + claimPlayback 的入参）。
  bool get slotIsPlaying;

  /// 已有封面吗（收回去之后仍有画面 → 牺牲者的"损失最小"排序用）。
  bool get slotHasPoster;

  /// 拿到槽位：开始初始化播放器。
  void onSlotGranted();

  /// 槽位被收走（让位给更该拿的卡片）：**不落错误态**，交还后重新排队。
  void onSlotRevoked();
}

/// 诊断输出注入点：默认 LogService，测试塞个收集器。
typedef PoolNoteSink = void Function(String source, String message);

/// 学到的并发上限存档点：默认 StorageService；测试塞收集器。
typedef BudgetSaver = void Function(int value);

/// 并发上限外部覆盖点（如保守单路兼容模式锁定为 1）。返回 null 表示走自适应策略。
typedef MaxConcurrentOverride = int? Function();

class VideoDecoderPool {
  VideoDecoderPool({
    DecoderPolicy? policy,
    PoolNoteSink? note,
    BudgetSaver? saveBudget,
    MaxConcurrentOverride? maxOverride,
    this.handoffSettle = kDecoderHandoffSettle,
    this.playerPriorityHold = kPlayerPriorityHold,
  })  : policy = policy ?? DecoderPolicy(),
        _note = note ?? LogService.recordNote,
        _saveBudget = saveBudget ?? StorageService.setDecodeBudget,
        _maxOverride = maxOverride;

  /// 收走槽位后，硬解实例真正离开 MediaCodec 需要的时间。
  ///
  /// `controller.dispose()` → 原生 `release()` 是异步的，接手方如果立刻
  /// `prepare()`，Media3 会判定"硬解实例仍被占用"直接回退软解 —— 这就是
  /// "打开第二个视频变成软解"的直接成因。测试把它设成 [Duration.zero]。
  static const Duration kDecoderHandoffSettle = Duration(milliseconds: 260);

  /// 有人正在播时，**自动抓封面**的初始化要先让出这么久再抢解码器。
  ///
  /// 播放者要等 [kDecoderHandoffSettle] 才能 prepare；如果排队抓封面的卡片和它
  /// 同时冲上去，先到 codec server 的那个会把唯一一路硬解占走，用户点的那张反而
  /// 落回软解 —— 正是要修的现象。让自动路径慢一步，播放路径就稳拿硬解。
  static const Duration kPlayerPriorityHold = Duration(milliseconds: 900);

  /// 见 [kDecoderHandoffSettle]；测试注入零延迟。
  final Duration handoffSettle;

  /// 见 [kPlayerPriorityHold]；测试注入零延迟。
  final Duration playerPriorityHold;

  /// 全局实例（懒建）：起点取上次会话学到的并发上限。
  /// 不做成 static final 是为了不让库加载就去读 path_provider。
  static VideoDecoderPool? _shared;
  static VideoDecoderPool get shared => _shared ??= _withStoredBudget();

  static VideoDecoderPool _withStoredBudget() {
    final stored = StorageService.getDecodeBudget();
    return VideoDecoderPool(
      policy: DecoderPolicy(
        budget: DecodeBudget(
          initial: stored ?? 2,
          ceiling: DecoderPolicy.kFallbackAwareCeiling,
          successStreakToRaise: DecoderPolicy.kSuccessStreakToRaise,
        ),
      ),
      // 「优先软解」类模式并发上限锁 1：软解用 CPU，多路同解会互相拖垮，
      // 而且在缺陷机型上多开只会多几块斜纹。null 表示沿用自适应 DecoderPolicy。
      maxOverride: () =>
          StorageService.getVideoCompatMode().maxConcurrentOverride,
    );
  }

  final DecoderPolicy policy;
  final PoolNoteSink _note;
  final BudgetSaver _saveBudget;
  final MaxConcurrentOverride? _maxOverride;

  /// 已占槽的（含正在 initialize 的 —— 解码器是在 prepare 阶段就申请的，
  /// in-flight 必须算进来，否则并发失控）。
  final List<DecoderSlotUser> _live = <DecoderSlotUser>[];

  /// 排队的。
  final List<DecoderSlotUser> _waiting = <DecoderSlotUser>[];

  /// 其中"用户点了要播"的：排队排最前，抢占时放宽牺牲者范围。
  final Set<DecoderSlotUser> _urgent = <DecoderSlotUser>{};

  /// 当前**正在播**的那一张 —— 硬解实例的持有者。
  ///
  /// 硬解实例是全机共享的稀缺资源：部分机型（正是报斜切/绿纹的那批联发科）
  /// 只肯给 1 路硬件 AVC 解码。所以"谁在播谁拿硬解"是硬约束，不是偏好：
  /// 只要还有别人的播放器活着，Media3 在 `prepare()` 时抢不到硬解就会静默
  /// 回退软解 —— 用户看到的就是"第一个视频硬解、打开第二个变软解"。
  DecoderSlotUser? _player;

  /// 最近一次"把槽位收走"的时刻，用于 [waitForHandoff]。
  DateTime? _lastRevokeAt;

  /// 抓帧不可用（真机 `RepaintBoundary.toImage` 抓不到 Texture）。
  ///
  /// 确认后**不再限制并发**：封面只能来自活着的播放器，压着并发等于让卡片
  /// 没有画面 —— 那比不设池子还差（必须存在的兜底，见 twitter_video.dart）。
  bool captureUnavailable = false;

  int get max {
    final override = _maxOverride?.call();
    if (override != null && override >= 1) return override;
    return policy.maxConcurrent;
  }
  int get liveCount => _live.length;
  int get waitingCount => _waiting.length;

  /// 当前持有"硬解槽位"的那张卡片（没人在播时为 null）。
  DecoderSlotUser? get player => _player;

  /// 距最近一次收走槽位过了多久（从没发生过则为 null）。
  Duration? get sinceLastRevoke {
    final at = _lastRevokeAt;
    return at == null ? null : DateTime.now().difference(at);
  }

  /// 等硬解实例真正被释放（见 [kDecoderHandoffSettle]）。
  ///
  /// 刚抢到槽位的卡片在 `initialize()` 之前必须 `await` 这一下，否则会拿到软解。
  /// 没有刚发生过收走时立即返回，不引入任何额外延迟。
  ///
  /// [forPlayback] = 这次初始化是为用户播放服务的（会调用 `claimPlayback`）。
  /// 为 false 时如果此刻有人正在播，还要多等 [kPlayerPriorityHold] 把硬解让给它。
  Future<void> waitForHandoff({bool forPlayback = false}) async {
    var delay = Duration.zero;
    final elapsed = sinceLastRevoke;
    if (elapsed != null && elapsed < handoffSettle) {
      delay = handoffSettle - elapsed;
    }
    if (!forPlayback && _player != null && delay < playerPriorityHold) {
      delay = playerPriorityHold;
    }
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }

  /// 这张卡片在排队等槽位（还没开始初始化）。
  bool isWaiting(DecoderSlotUser s) => _waiting.contains(s);

  /// 申请槽位：有空位立刻给，否则排队。返回是否**已经**拿到。
  ///
  /// [urgent] = 用户明确点了这张要播：**清场**，见 [pump]。
  bool request(DecoderSlotUser s, {bool urgent = false}) {
    if (urgent) _urgent.add(s);
    if (_live.contains(s)) return true;
    if (!_waiting.contains(s)) _waiting.add(s);
    pump();
    return _live.contains(s);
  }

  /// 交还槽位（抓到封面、失败、被回收、dispose 都走这里）。
  void release(DecoderSlotUser s) {
    _live.remove(s);
    _waiting.remove(s);
    _urgent.remove(s);
    if (identical(_player, s)) _player = null;
    if (!_pumping) pump();
  }

  /// 这张卡片开始播了：它就是硬解实例的持有者，其余持槽者一律让位。
  ///
  /// 与 [request] 分开是因为两条入口的时机不同：`request(urgent:)` 发生在
  /// 初始化**之前**（用户点了封面，还没解码器），而这里发生在**已经开始播**
  /// 之后（暂停后重新播放、或本来就持有槽位的那张点了播放键）。
  void claimPlayback(DecoderSlotUser s) {
    if (!s.slotMounted) return;
    _player = s;
    _waiting.remove(s);
    _urgent.remove(s);
    _live.remove(s);
    _live.insert(0, s);
    final others = _live.where((e) => !identical(e, s)).toList(growable: false);
    if (others.isEmpty) return;
    final wasPumping = _pumping;
    _pumping = true;
    try {
      for (final v in others) {
        _live.remove(v);
      }
      for (final v in others) {
        _revoke(v);
      }
    } finally {
      _pumping = wasPumping;
    }
    _note('decode', '硬解槽位切换到正在播放的卡片，${others.length} 张让位');
    if (!wasPumping) pump();
  }

  /// 滚动时提醒重排（可见性变了）。
  void nudge() => pump();

  /// 一次成功（抓到封面）：连续成功够数才谨慎上调，并存档。
  void noteSuccess() {
    if (!policy.noteSuccess()) return;
    _afterBudgetChange('连续抓帧成功');
  }

  /// 记录一次"槽位被占多久"。init 是网络耗时（moov+首帧），抓帧是渲染操作，
  /// 差 1~2 个量级 —— 这条日志就是为了证明/推翻"抓封面白不白占解码器"。
  void noteSlotHold({int? initMs, int? captureMs}) {
    if (initMs == null) return;
    _note(
      'decode',
      '槽位占用 ${(initMs / 1000).toStringAsFixed(1)}s'
      '（init ${(initMs / 1000).toStringAsFixed(1)}s'
      ' + 抓帧 ${captureMs ?? 0}ms）'
      ' 上限=$max 存活=${_live.length} 排队=${_waiting.length}',
    );
  }

  /// 抓帧确认不可用：解除并发限制并放行所有排队者。
  void noteCaptureUnavailable() {
    if (captureUnavailable) return;
    captureUnavailable = true;
    pump();
  }

  /// pump 期间只允许入队，不许直接发槽位。
  ///
  /// 否则：抢占时 evict 占位者 → 它 onSlotRevoked 里立刻重新 request → 此刻
  /// 槽位正好空着 → 它把自己又要回去了，抢占白做（死循环）。
  bool _pumping = false;

  /// 分槽：可见优先；用户点播直接清场（见 [pump]）。
  void pump() {
    if (_pumping) return;
    _pumping = true;
    try {
      // 清理已卸载但尚未走完 release() 的残留引用（dispose 竞态护栏）。
      _waiting.removeWhere((s) => !s.slotMounted);
      _urgent.removeWhere((s) => !s.slotMounted);
      _live.removeWhere((s) => !s.slotMounted);
      if (_player != null && !_player!.slotMounted) _player = null;
      while (_waiting.isNotEmpty) {
        final waiter = _pickWaiter();
        if (waiter == null) return;
        // 用户点播 = 必须拿到**硬解**，而不只是"拿到一个槽位"：
        // 只要还有别的播放器活着（哪怕它在播、哪怕槽位没满），Media3 就会
        // 因为抢不到硬解实例而静默回退软解。所以先清场，再发槽。
        if (_urgent.contains(waiter)) {
          _evictAllExcept(waiter);
          _grant(waiter);
          _player = waiter;
          // 让位者已经在 onSlotRevoked 里重新排了队（此刻 _pumping 为真，
          // 它们只能入队），继续循环把空出来的槽位发出去。
          continue;
        }
        final hasHardCap = _maxOverride?.call() != null;
        if ((!hasHardCap && captureUnavailable) || _live.length < max) {
          _grant(waiter);
          continue;
        }
        // 自动排队者只在"能挤掉看不见且没在播的卡片"时才抢（避免来回抖动）。
        final victim = _pickVictim();
        if (victim == null) return;
        _live.remove(victim);
        _grant(waiter);
        _revoke(victim);
        // 一次只处理一个抢占，剩下的等下一轮（否则刚被打回的卡片立刻又抢，
        // 来回抖动）。
        return;
      }
    } finally {
      _pumping = false;
    }
  }

  /// 收走除 [keeper] 之外所有持槽者的槽位（用户点播 / 开始播放时的清场）。
  ///
  /// 必须只在 `_pumping == true` 时调用：让位者的 `onSlotRevoked` 会立刻重新
  /// `request()`，不挡住的话它会在这个空档里把自己刚让出去的槽位又要回来。
  void _evictAllExcept(DecoderSlotUser keeper) {
    final victims =
        _live.where((e) => !identical(e, keeper)).toList(growable: false);
    if (victims.isEmpty) return;
    for (final v in victims) {
      _live.remove(v);
    }
    for (final v in victims) {
      _revoke(v);
    }
    _note('decode', '硬解槽位清场：${victims.length} 张让位给正在播放的卡片');
  }

  /// 收走一个槽位并留下"何时收走"的印记（接手方要等硬解真正释放）。
  void _revoke(DecoderSlotUser v) {
    _lastRevokeAt = DateTime.now();
    _urgent.remove(v);
    if (identical(_player, v)) _player = null;
    v.onSlotRevoked();
  }

  void _grant(DecoderSlotUser s) {
    _waiting.remove(s);
    _urgent.remove(s);
    if (!_live.contains(s)) _live.add(s);
    s.onSlotGranted();
  }

  /// 挑排队者：**用户点的最优先**，其次看得见的，最后按排队顺序。
  DecoderSlotUser? _pickWaiter() {
    if (_waiting.isEmpty) return null;
    for (final w in _waiting) {
      if (_urgent.contains(w) && w.slotVisibleNow) return w;
    }
    for (final w in _waiting) {
      if (_urgent.contains(w)) return w;
    }
    for (final w in _waiting) {
      if (w.slotVisibleNow) return w;
    }
    return _waiting.first;
  }

  /// 自动排队时的牺牲者：看不见 + 没在播；**有封面**的优先（收回仍有画面）。
  ///
  /// 用户点播不走这里 —— 那条路径直接清场（见 [pump]），因为"抢到硬解"和
  /// "挤掉一张卡片"是两件事：前者要求全机只剩它一个解码器。
  DecoderSlotUser? _pickVictim() {
    for (final e in _live) {
      if (!e.slotVisibleNow && !e.slotIsPlaying && e.slotHasPoster) return e;
    }
    for (final e in _live) {
      if (!e.slotVisibleNow && !e.slotIsPlaying) return e;
    }
    return null;
  }

  void _afterBudgetChange(String why) {
    // 存档：否则每次冷启动都要重新试探一遍。
    _saveBudget(policy.maxConcurrent);
    _note(
      'decode',
      '$why → 并发上限=${policy.maxConcurrent}'
      '（存活=${_live.length} 排队=${_waiting.length}）',
    );
  }

  /// 测试注入用：清掉共享实例（下次 .shared 重建）。
  static void resetSharedForTests() => _shared = null;
}
