// Twitter 用户模型，包括基本信息和统计

// ─── JSON 容错辅助 ─────────────────────────────────────────────────────────
//
// API 字段缺失或类型不符时不应让 TypeError 崩掉整个页面：统一走这几个辅助
// 函数取值，缺失/类型不符时返回空值而不是强转抛错。

/// 取字符串：缺失返回 [fallback]，非字符串用 toString() 兜底。
String _str(dynamic v, [String fallback = '']) =>
    v == null ? fallback : v.toString();

/// 取可空字符串：缺失返回 null。
String? _strOrNone(dynamic v) => v == null ? null : v.toString();

/// 取 int：缺失/不可解析返回 null；兼容 API 返回字符串型数字（"42"）。
int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

/// 取 List：缺失或类型不符返回空列表。
List<dynamic> _list(dynamic v) => v is List ? v : const <dynamic>[];

/// 取 Map：缺失或类型不符返回空 Map。
Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

/// 解析 JSON 的 tags 值为 `Map<String, int>`。
///
/// 公开：模型层与 API 层（TwitterApi.getTagWeights）共用同一套口径。
/// 契约：tags 形如 `{"女性":5,"自拍":3}`，权重**可为负**且服务端目前不过滤 0，
/// 客户端不丢任何键。容错与上面的解析族一致：
/// - null / 非 Map → 空 Map（不崩）；
/// - 值走 [_int]：兼容字符串数字（"3" → 3）、负数原样保留、
///   解析不出 int 的值（乱码串 / null）兜底为 0。
Map<String, int> parseTagWeights(dynamic v) =>
    _map(v).map((k, val) => MapEntry(k, _int(val) ?? 0));

// ─── 模型 ──────────────────────────────────────────────────────────────────

class TwitterUser {
  final String username;
  final String? nick;
  final String? avatar;
  final int? totalUrls;

  /// 随用户对象附带的标签权重。新版列表/搜索接口（by=username|nick|tag 的
  /// `[]User`，尤其 by=tag 的命中结果）每项带 `tags` 字段；缺失或类型不符
  /// 回退为空 Map（见 [parseTagWeights]）。注意 UserMetaData 的
  /// account_info（Twitter 侧资料）不含此字段，保持默认空。
  final Map<String, int> tags;

  TwitterUser({
    required this.username,
    this.nick,
    this.avatar,
    this.totalUrls,
    this.tags = const <String, int>{},
  });

  factory TwitterUser.fromJson(Map<String, dynamic> json) {
    return TwitterUser(
      username: _str(json['username']),
      nick: _strOrNone(json['nick']),
      avatar: _strOrNone(json['avatar']),
      totalUrls: _int(json['total_urls']),
      tags: parseTagWeights(json['tags']),
    );
  }
}

// 时间线条目，表示图片或视频资源
class TimelineItem {
  final String url;
  final String type;
  final String? date;

  TimelineItem({required this.url, required this.type, this.date});

  factory TimelineItem.fromJson(Map<String, dynamic> json) {
    return TimelineItem(
      url: _str(json['url']),
      type: _str(json['type']),
      date: _strOrNone(json['date']),
    );
  }
}

// 用户完整信息，包含账号信息、时间线及资源总数
class UserMetaData {
  final TwitterUser accountInfo;
  final List<TimelineItem> timeline;
  final int totalUrls;

  UserMetaData({
    required this.accountInfo,
    required this.timeline,
    required this.totalUrls,
  });

  factory UserMetaData.fromJson(Map<String, dynamic> json) {
    final info = _map(json['account_info']);
    final timeline = _list(json['timeline'])
        .where((e) => e is Map)
        .map((e) => TimelineItem.fromJson(_map(e)))
        .toList();
    return UserMetaData(
      accountInfo: TwitterUser(
        username: _str(info['name']),
        nick: _strOrNone(info['nick']),
        avatar: _strOrNone(info['profile_image']),
        totalUrls: _int(json['total_urls']),
      ),
      timeline: timeline,
      totalUrls: _int(json['total_urls']) ?? timeline.length,
    );
  }
}

// 排行榜条目，记录用户名及投票数
class RankingEntry {
  final String username;
  final int votes;

  RankingEntry({required this.username, required this.votes});

  factory RankingEntry.fromJson(Map<String, dynamic> json) {
    return RankingEntry(
      username: _str(json['username']),
      votes: _int(json['votes']) ?? 0,
    );
  }
}

// Emoji 排行周期数据，包含日、周、月榜单
class EmojiPeriodData {
  final List<RankingEntry> day;
  final List<RankingEntry> week;
  final List<RankingEntry> month;

  EmojiPeriodData({required this.day, required this.week, required this.month});

  factory EmojiPeriodData.fromJson(Map<String, dynamic> json) {
    List<RankingEntry> _entries(String key) => _list(json[key])
        .where((e) => e is Map)
        .map((e) => RankingEntry.fromJson(_map(e)))
        .toList();
    return EmojiPeriodData(
      day: _entries('day'),
      week: _entries('week'),
      month: _entries('month'),
    );
  }
}
