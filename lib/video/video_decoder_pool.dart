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
//   4. 分槽**可见优先**；用户点播（urgent）可以抢占任何非播放卡片。
//
// Android 的硬件 AVC 解码器实例是稀缺资源（常见 2~4 个），而详情页
// `cacheExtent` 1800px、卡片约 200px，一次构建十几张卡片 —— 不设上限必然打架。

import '../services/log_service.dart';
import '../services/storage_service.dart';
import '../utils/decode_budget.dart';
import 'decoder_policy.dart';

/// 池子眼里的"一张卡片"。实现在 [TwitterVideo] 的 State 上。
abstract class DecoderSlotUser {
  /// widget 还挂在树上吗（池子可能持有刚 dispose 的引用一个 microtask）。
  bool get slotMounted;

  /// 还需要槽位吗 = 还没有封面。
  bool get slotNeedsPoster;

  /// 现在是否在视口内（分槽优先级）。
  bool get slotVisibleNow;

  /// 正在播放吗（抢占时的保护对象 + markPlaying 的入参）。
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

class VideoDecoderPool {
  VideoDecoderPool({
    DecoderPolicy? policy,
    PoolNoteSink? note,
    BudgetSaver? saveBudget,
  })  : policy = policy ?? DecoderPolicy(),
        _note = note ?? LogService.recordNote,
        _saveBudget = saveBudget ?? StorageService.setDecodeBudget;

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
    );
  }

  final DecoderPolicy policy;
  final PoolNoteSink _note;
  final BudgetSaver _saveBudget;

  /// 已占槽的（含正在 initialize 的 —— 解码器是在 prepare 阶段就申请的，
  /// in-flight 必须算进来，否则并发失控）。
  final List<DecoderSlotUser> _live = <DecoderSlotUser>[];

  /// 排队的。
  final List<DecoderSlotUser> _waiting = <DecoderSlotUser>[];

  /// 其中"用户点了要播"的：排队排最前，抢占时放宽牺牲者范围。
  final Set<DecoderSlotUser> _urgent = <DecoderSlotUser>{};

  /// 抓帧不可用（真机 `RepaintBoundary.toImage` 抓不到 Texture）。
  ///
  /// 确认后**不再限制并发**：封面只能来自活着的播放器，压着并发等于让卡片
  /// 没有画面 —— 那比不设池子还差（必须存在的兜底，见 twitter_video.dart）。
  bool captureUnavailable = false;

  int get max => policy.maxConcurrent;
  int get liveCount => _live.length;
  int get waitingCount => _waiting.length;

  /// 这张卡片在排队等槽位（还没开始初始化）。
  bool isWaiting(DecoderSlotUser s) => _waiting.contains(s);

  /// 申请槽位：有空位立刻给，否则排队。返回是否**已经**拿到。
  ///
  /// [urgent] = 用户明确点了这张要播，必须抢到（见 [_pickUrgentVictim]）。
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
    if (!_pumping) pump();
  }

  /// 正在使用的挪到队首（不影响能否被抢占；抢占永远不碰正在播的）。
  void markPlaying(DecoderSlotUser s) {
    _live.remove(s);
    _live.insert(0, s);
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

  /// 分槽：可见优先；槽位被看不见的卡片占着时，收回给看得见的排队者。
  void pump() {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_waiting.isNotEmpty) {
        final waiter = _pickWaiter();
        if (waiter == null) return;
        if (captureUnavailable || _live.length < max) {
          _grant(waiter);
          continue;
        }
        final urgent = _urgent.contains(waiter);
        // 自动排队者只在"能挤掉看不见且没在播的卡片"时才抢（避免来回抖动）；
        // 用户点的那张必须抢到，牺牲者放宽到任何非播放卡片。
        final victim = urgent ? _pickUrgentVictim() : _pickVictim();
        if (victim == null) return;
        _live.remove(victim);
        _grant(waiter);
        victim.onSlotRevoked();
        // 一次只处理一个抢占，剩下的等下一轮（否则刚被打回的卡片立刻又抢，
        // 来回抖动）。
        return;
      }
    } finally {
      _pumping = false;
    }
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

  /// 用户点播时的牺牲者，按"损失最小"排序：
  ///   ① 看不见 + 没在播 + 有封面（收回仍有画面，观感无损）
  ///   ② 没在播 + 有封面（看得见，但至少有画面）
  ///   ③ 没在播
  ///   ④ 正在播的（用户已经在看新的了，停旧的可接受）
  DecoderSlotUser? _pickUrgentVictim() {
    for (final e in _live) {
      if (!e.slotVisibleNow && !e.slotIsPlaying && e.slotHasPoster) return e;
    }
    for (final e in _live) {
      if (!e.slotIsPlaying && e.slotHasPoster) return e;
    }
    for (final e in _live) {
      if (!e.slotIsPlaying) return e;
    }
    return _live.isEmpty ? null : _live.last;
  }

  /// 自动排队时的牺牲者：看不见 + 没在播；**有封面**的优先（收回仍有画面）。
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
