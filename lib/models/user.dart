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

/// 标签云的一行：`GET /api/tag-cloud?limit=N` 的元素，
/// 实测形如 `{"Tag":"女性","Count":7579}`。
///
/// ⚠️ **键是大写的 `Tag`/`Count`** —— Go 那边结构体没写 json tag，gin 按
/// 字段名原样序列化。所以不能按小写 `tag`/`count` 取（那样会静默全空）。
/// 为了以后后端补上 json tag、或换别的实现，这里 [fromJson] **大小写不敏感**
/// 地找键，两种写法都能吃。
///
/// [count] 是**这个标签下有多少个用户**（账号数），不是票数。
///
/// 实测三路一致（2026-10-05）：
/// - tag-cloud `女性` 的 `Count` = 7591；
/// - `/api/tag/女性` 的 `total`（该标签下账号列表总数）= **7591**，与之相等；
/// - 178 个标签计数总和 = 23895 ≈ 1.45 × 全站账号数（16427），对应「一个账号
///   有多个标签就被各标签各计一次」。
///
/// ⚠️ 此前这里写的是「票数/权重累计，不是用户数」，**那是错的**：它把标签
/// 计数和 emoji poll 的投票数混了（`?by=tag` 只回 11 条是**分页上限**，
/// 不能拿来反推计数口径）。UI 应当标「N 人」。
class TagCount {
  final String tag;
  final int count;

  const TagCount({required this.tag, required this.count});

  factory TagCount.fromJson(Map<String, dynamic> json) {
    // 大小写不敏感地取值：先按标准键拿，拿不到再退化到小写（反之亦然）。
    // 空标签名直接丢弃的话没有意义，调用方自行过滤。
    return TagCount(
      tag: _str(json['Tag'] ?? json['tag']),
      count: _int(json['Count'] ?? json['count']) ?? 0,
    );
  }

  /// 解析标签云响应，**保持服务端原序**。
  ///
  /// 这里刻意**不排序**：`fromJson` 的职责是「把 JSON 变成对象」，排序是另一个
  /// 决定。把它藏进来会让 `listFromJson` 这个名字骗掉所有调用方——读代码的人
  /// 以为拿到的是服务端顺序，实际拿到的是别人排过的序，而「为什么是这个顺序」
  /// 只有实现者知道。
  ///
  /// 要**人数降序**（人数多的在前）的展示序，请显式用 [sortedByCountDesc]：
  ///
  /// ```dart
  /// final cloud = sortedByCountDesc(TagCount.listFromJson(resp.data));
  /// ```
  static List<TagCount> listFromJson(dynamic raw) =>
      _list(raw)
          .whereType<Map>()
          .map((e) => TagCount.fromJson(_map(e)))
          .where((e) => e.tag.isNotEmpty)
          .toList();
}

/// **人数降序**（人数多的在前），同数按标签名升序——标签展示的唯一标准序。
///
/// ⚠️ 为什么是显式函数，而不是让 [TagCount.listFromJson] 顺手排：
///
/// - 上一版把排序塞进 `listFromJson`，函数名里没有 sort，**排序成了解析的
///   副作用**。两个后果：(a) 读代码的人无法得知顺序已被改过；(b) 只想解析的
///   调用方被迫拿到一个被排过序的列表，而这个顺序「是谁的决定」无从追溯。
/// - 顺序是**产品决定**（人数多的排前面），不是解析的必然结果。显式命名后，
///   「这里要展示序」和「这里只要数据」在调用点上一眼可辨。
///
/// **就地排序**并返回同一个引用。传入的列表若还要保留原序，请调用方自己
/// 先 `List.of(...)` —— 这不是本函数该管的。
List<TagCount> sortedByCountDesc(List<TagCount> items) {
  items.sort(compareTagCountDesc);
  return items;
}

/// 「人数降序 + 同数按名升序」的**唯一比较器定义**。
///
/// 供 [sortedByCountDesc] 使用；其它按「人数」排的判据（如搜索推荐的次级
/// 排序）也调它，**不要重写一遍**——三处各写一份时，改动规则必然漏一处。
int compareTagCountDesc(TagCount a, TagCount b) {
  final byCount = b.count.compareTo(a.count);
  return byCount != 0 ? byCount : a.tag.compareTo(b.tag);
}

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

  /// 该用户是否**带着** [tag] 这个标签键（只看键是否存在，不看权重）。
  /// 见 [matchesTagFilter] 的口径说明。
  bool hasTagKey(String tag) => tags.containsKey(tag);

  /// 取某标签的权重；没有这个标签返回 null（与「权重为 0」区分开）。
  int? weightOf(String tag) => tags[tag];

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

// ─── 按标签过滤（纯逻辑，独立可测）──────────────────────────────────────────

/// 标签过滤的匹配口径：**只看 `tags` 里的键是否存在，权重符号不参与判定。**
///
/// 也就是说 `{"COS": -1}` 也算"命中 COS"。理由：
///
/// - 服务端**明确允许负权重**（`parseTagWeights` 原样保留负数），负权在这里
///   的语义是"这个标签被打过反向票/被否认"，而不是"这个用户跟这个标签无关"。
///   把负权直接判成不匹配，等于用**列表的筛选口径**去改写**数据本身的含义**，
///   用户选了"露奶"结果刷出"这人其实是被判定不含露奶"的账号，比多显示几条更糟。
/// - 服务端 `by=tag` 反查本来就只取**正权重**，拿它当"什么算命中"的模板会
///   让本地过滤和服务端反查给出**两个不同的用户集合**——同一件事两个答案。
///   统一成"键存在即命中"，本地过滤是对服务端口径的**超集**，不会出现
///   "页面上有、服务端说没有"或反之的分裂。
///
/// 权重仍然有用，只是不当门禁：当命中用户的权重是负数时，UI 用红色 chip
/// 标出（见 user_list_screen 的 _TagFilterBar），让"这条是反向票"可见。
bool matchesTagFilter(TwitterUser user, String tag) =>
    user.tags.containsKey(tag);

/// 按选中的标签过滤用户（**纯**标签维度，不含屏蔽 / Gay 模式）。
///
/// [selectedTags] 为空集合 = 不过滤，原样返回（保持顺序与全部元素）。
///
/// 多选之间是 **OR（并集）**：命中任意一个被选中的标签即保留。
///
/// 注意：返回的是**同一个对象的新 List**，不改原列表。屏蔽 / Gay 模式的判定
/// 见 StorageService.shouldHideUser，由调用方串联（见 [applyVisibleRules]）。
List<TwitterUser> filterUsersByTags(
  List<TwitterUser> users,
  Set<String> selectedTags,
) {
  if (selectedTags.isEmpty) return List<TwitterUser>.of(users);
  final result = <TwitterUser>[];
  for (final u in users) {
    for (final t in selectedTags) {
      if (matchesTagFilter(u, t)) {
        result.add(u);
        break;
      }
    }
  }
  return result;
}

/// 把屏蔽 / 屏蔽标签 / Gay 模式三条本地规则叠加到**已经算好的**用户列表上，
/// 产出一份可直接喂给 ListView.builder 的**最终可见列表**。
///
/// 单独抽出来的原因见 user_list_screen 的注释：过滤**绝不能**在
/// ListView.builder 的 itemBuilder 里做 —— 那样 itemCount 与实际渲染项对不上，
/// 被隐藏的行仍然占着 index，滑动到底会提前触发加载更多，尾部还会凭空多出
/// 一段空白（现有 `SizedBox.shrink()` 写法就是这么坏的）。
List<TwitterUser> applyVisibleRules(
  List<TwitterUser> users,
  bool Function(String username, Map<String, int> tags) shouldHide,
) =>
    users.where((u) => !shouldHide(u.username, u.tags)).toList();

/// 把「按标签过滤」与「本地隐藏规则」串成一条：结果就是列表该渲染的那一批。
///
/// 顺序刻意是 **先标签、后隐藏**：标签过滤是用户主动选的，隐藏规则是用户
/// 配的屏蔽/Gay 规则，后者优先级更高（两者同时命中时一定被藏掉）。
List<TwitterUser> visibleUsers(
  List<TwitterUser> users,
  Set<String> selectedTags,
  bool Function(String username, Map<String, int> tags) shouldHide,
) =>
    applyVisibleRules(filterUsersByTags(users, selectedTags), shouldHide);

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
