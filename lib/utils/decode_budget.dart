// decode_budget.dart
// 解码器并发上限的**自适应策略**（纯逻辑，可单测）。
//
// 为什么不能写死：Android 的硬件 AVC 解码器实例数**因设备而异** —— 常见 2~4，
// 720p60 High profile 往往只吃得下 2 个，但不少机型能开 4 个以上。系统没有 API
// 能查"本机允许几个"，所以只能试：
//
//   * 连续成功 → 谨慎上调（说明还有余量）；
//   * 出现 MediaCodec 类失败 → 立即下调（说明超了），并清掉连击。
//
// 上下限都有：`floor` 保证永远能推进（哪怕只有一路），`ceiling` 防止无限上调
// （并发越高，低端机上撞硬解上限的概率越大，收益却是递减的）。
//
// 学到的值由调用方存档，下次启动直接当起点 —— 否则每次冷启动都要再撞一次墙。

class DecodeBudget {
  /// 下调不会低于这个值：哪怕设备只允许一路，也得能一张一张往下走。
  final int floor;

  /// 上调不会超过这个值。
  final int ceiling;

  /// 连续成功多少次才敢 +1。刚启动时保守一点，避免一上来就撞上限。
  final int successStreakToRaise;

  int _value;
  int _streak = 0;

  DecodeBudget({
    int initial = 2,
    this.floor = 1,
    this.ceiling = 4,
    this.successStreakToRaise = 3,
  }) : _value = initial.clamp(floor, ceiling);

  /// 当前上限。
  int get value => _value;

  /// 当前连续成功次数（测试与日志用）。
  int get streak => _streak;

  /// 设备是否已被确认"比初始值更宽"（值被上调过）。
  bool get raised => _value > floor;

  /// 一次成功（抓到一帧封面 / 完成一次播放初始化）。
  /// 返回 true 表示上限被上调了。
  bool onSuccess() {
    _streak++;
    if (_streak >= successStreakToRaise && _value < ceiling) {
      _value++;
      _streak = 0;
      return true;
    }
    if (_streak >= successStreakToRaise) {
      // 已经到顶：连击清零，免得一直累加。
      _streak = 0;
    }
    return false;
  }

  /// 一次 MediaCodec 类失败。返回 true 表示上限被下调了。
  ///
  /// **立即下调**、不等到连续攒够：撞上限的代价就是这一路失败，再试一次多半还撞。
  bool onCodecFailure() {
    _streak = 0;
    if (_value <= floor) return false;
    _value--;
    return true;
  }

  @override
  String toString() => 'DecodeBudget(value=$_value, streak=$_streak, '
      'floor=$floor, ceiling=$ceiling)';
}
