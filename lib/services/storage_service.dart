import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class StorageService {
  static const _kFavMap = 'fav-map';
  static const _kBlockMap = 'block-map';
  static const _kTagRules = 'tag-rules';
  static const _kCustomTags = 'user_custom_tags';
  static const _kSearchHistory = 'search-history';
  static const _kDecodeBudget = 'decode-budget';
  static const _kGayMode = 'gay-mode';
  static const _kGayTags = 'gay-tags';
  /// **跨端契约**：Gay 模式默认词表。与图站 `gallery/static/home.js` 的
  /// `DEFAULT_GAY_TAGS` 必须是同一份。
  ///
  /// 选词依据（2026-10-04 实测 data/tags.db 的 account_tags）：
  ///
  /// | 词 | 实际带此标签的账号数 |
  /// |---|---|
  /// | 男性 | 141 |
  /// | 男娘 | 214 |
  /// | 男同 | 19 |
  /// | 露屌 | 29 |
  /// | 阳痿 | 5 |
  /// | 人妖 | 0 |
  ///
  /// 知识库里另一份记载（notes/facts-twitter-pic-exclude-tag-cloud）写的
  /// `gay / yaoi / futanari / 男同 / 基 / bl` **与线上代码不符**——那 5 个
  /// 英文/单字词在库里**一条记录都没有**（不分大小写、不限权重均查不到）。
  /// 换句话说：知识库那份若真的生效，会把线上正在过滤的 341 个账号**全部放行**，
  /// 而不是多过滤几个。那份记载已按实测更正。
  ///
  /// ⚠️ 改这里必须同步改 home.js 的 DEFAULT_GAY_TAGS；
  /// test/gay_tag_contract_test.dart 会把两端的字面量钉在一起，改漏就红。
  static const List<String> kDefaultGayTags = ['男性', '男娘', '人妖', '露屌', '阳痿', '男同'];

  static bool _loaded = false;
  static Map<String, String> _memory = {};
  static File? _file;

  static Future<void> ensureInitialized() async {
    if (_loaded) return;
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/storage.json');
    if (await _file!.exists()) {
      try {
        final content = await _file!.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map) {
          _memory = decoded.cast<String, String>();
        }
      } catch (_) {}
    }
    _loaded = true;
  }

  /// 清空所有存储数据。
  static Future<void> clearAll() async {
    _memory = {};
    // 必须 await：设置页「清除数据」await 完就去改 UI 了，不等的化磁盘还没
    // 写完就返回，中途被系统杀进程时旧数据会残留（等于没清）。
    await _flush();
  }

  static Future<void> _flush() async {
    // 串行化 + 临时文件原子替换：快速连续 toggle 时多个 writeAsString
    // 并发交错可能写坏 storage.json；rename 保证读到的是完整文件。
    //
    // 链里的代码**只能**调 [_doFlush]，绝不能回头调 _flush —— _flush 会重新
    // 赋值 _flushChain，链里的回调去等链自己完成就是死锁（LogService 里踩过，
    // CI 上两个用例 30s 超时才暴露，analyze 抓不到）。
    _flushChain = _flushChain.then((_) => _doFlush());
    return _flushChain;
  }

  static Future<void> _doFlush() async {
    try {
      final f = _file;
      if (f == null) return;
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(_memory));
      await tmp.rename(f.path);
    } catch (_) {}
  }

  /// 串行写盘链，保证并发写入不会交错。
  static Future<void> _flushChain = Future.value();

  /// 仅供测试：清空内存态并解除已加载标记，
  /// 下次 [ensureInitialized] 会重新从磁盘读取。
  static void resetForTests() {
    _loaded = false;
    _memory = {};
    _file = null;
    _flushChain = Future.value();
  }

  /// 仅供测试：等待所有挂起的写盘完成（写盘是串行链，见 [_flush]）。
  static Future<void> debugFlushPending() => _flushChain;


  static Map<String, dynamic> _readMap(String key) {
    final s = _read(key);
    if (s.isEmpty) return {};
    try {
      final o = jsonDecode(s);
      if (o is Map) return o.cast<String, dynamic>();
    } catch (_) {}
    return {};
  }

  static void _writeMap(String key, Map<String, dynamic> value) {
    _write(key, jsonEncode(value));
  }

  static String _read(String key) => _memory[key] ?? '';
  static void _write(String key, String value) {
    _memory[key] = value;
    unawaited(_flush());
  }

  // --- fav-map ---
  static Map<String, dynamic> getFavMap() => _readMap(_kFavMap);
  static void setFavMap(Map<String, dynamic> map) => _writeMap(_kFavMap, map);
  static bool isFav(String username) => getFavMap()[username] == true;
  static void toggleFav(String username) {
    final map = getFavMap();
    if (map[username] == true) {
      map.remove(username);
    } else {
      map[username] = true;
    }
    setFavMap(map);
  }

  // --- block-map ---
  static Map<String, dynamic> getBlockMap() => _readMap(_kBlockMap);
  static void setBlockMap(Map<String, dynamic> map) => _writeMap(_kBlockMap, map);
  static bool isBlocked(String username) => getBlockMap()[username] == true;
  static void toggleBlock(String username) {
    final map = getBlockMap();
    if (map[username] == true) {
      map.remove(username);
    } else {
      map[username] = true;
    }
    setBlockMap(map);
  }

  // --- tag-rules ---
  static Map<String, dynamic> getTagRules() => _readMap(_kTagRules);
  static void setTagRules(Map<String, dynamic> rules) => _writeMap(_kTagRules, rules);

  static List<String> getHighlightTags() {
    final rules = getTagRules();
    final h = rules['highlight'];
    if (h is List) return h.cast<String>();
    return [];
  }

  static List<String> getBlockTags() {
    final rules = getTagRules();
    final b = rules['block'];
    if (b is List) return b.cast<String>();
    return [];
  }

  static void setHighlightTags(List<String> tags) {
    final rules = getTagRules();
    rules['highlight'] = tags;
    setTagRules(rules);
  }

  static void setBlockTags(List<String> tags) {
    final rules = getTagRules();
    rules['block'] = tags;
    setTagRules(rules);
  }

  // --- custom tags ---
  static List<String> getCustomTags() {
    final s = _read(_kCustomTags);
    if (s.isEmpty) return [];
    try {
      final list = jsonDecode(s);
      if (list is List) return list.cast<String>();
    } catch (_) {}
    return [];
  }

  static void setCustomTags(List<String> tags) {
    _write(_kCustomTags, jsonEncode(tags));
  }

  // --- decode-budget（自适应学到的解码器并发上限）---
  /// 上次会话试出来的并发上限。取不到就返回 null（由调用方用默认值）。
  static int? getDecodeBudget() {
    final v = int.tryParse(_read(_kDecodeBudget));
    if (v == null || v < 1) return null;
    return v;
  }

  static void setDecodeBudget(int value) => _write(_kDecodeBudget, '$value');

  // --- search-history ---
  static List<String> getSearchHistory() {
    final s = _read(_kSearchHistory);
    if (s.isEmpty) return [];
    try {
      final list = jsonDecode(s);
      if (list is List) return list.cast<String>();
    } catch (_) {}
    return [];
  }

  static void saveSearchHistory(List<String> history) {
    _write(_kSearchHistory, jsonEncode(history));
  }

  // --- gay-mode ---
  static bool isGayMode() {
    final v = _read(_kGayMode);
    if (v.isEmpty) return false;
    return v == 'true' || v == '1';
  }

  static void setGayMode(bool enabled) {
    _write(_kGayMode, enabled ? 'true' : 'false');
  }

  static bool toggleGayMode() {
    final next = !isGayMode();
    setGayMode(next);
    return next;
  }

  // --- gay-tags configuration ---
  static List<String> getGayTags() {
    final v = _read(_kGayTags);
    if (v.isEmpty) return List.of(kDefaultGayTags);
    try {
      final decoded = jsonDecode(v);
      if (decoded is List) {
        final list = decoded
            .map((e) => e.toString().trim().replaceFirst(RegExp(r'^#+'), ''))
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList();
        if (list.isNotEmpty) return list;
      }
    } catch (_) {}
    return List.of(kDefaultGayTags);
  }

  static void setGayTags(List<String> tags) {
    final clean = tags
        .map((e) => e.trim().replaceFirst(RegExp(r'^#+'), ''))
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    _write(_kGayTags, jsonEncode(clean));
  }

  static void addGayTag(String tag) {
    final clean = tag.trim().replaceFirst(RegExp(r'^#+'), '');
    if (clean.isEmpty) return;
    final current = getGayTags();
    if (!current.contains(clean)) {
      current.add(clean);
      setGayTags(current);
    }
  }

  static void removeGayTag(String tag) {
    final clean = tag.trim().replaceFirst(RegExp(r'^#+'), '');
    final current = getGayTags();
    current.remove(clean);
    setGayTags(current);
  }

  static void resetGayTags() {
    setGayTags(List.of(kDefaultGayTags));
  }

  /// 判断标签字典中是否包含任一 Gay 标签
  static bool hasGayTag(Map<String, int> tags, [Set<String>? customGayTags]) {
    final set = customGayTags ?? kGayTags;
    return tags.entries.any((e) => set.contains(e.key) && e.value > 0);
  }

  /// 判断用户标签是否符合当前 Gay 模式筛选（正好取反）：
  /// - Gay 模式开启：只显示包含 Gay 标签的用户
  /// - Gay 模式关闭：只显示不包含 Gay 标签的用户
  static bool matchesGayMode(Map<String, int> tags, [Set<String>? customGayTags]) {
    final isGay = isGayMode();
    final has = hasGayTag(tags, customGayTags);
    // ⚠️ 反向验证用（BROKEN ON PURPOSE）：恒返回 !has，丢掉 isGay 分支 ——
    // 「过滤写死成永远隐藏」。预期「Gay 模式**开启**…应该出现」用例变红。
    return !has;
  }

  /// **命中「标签管理 → 屏蔽」标签列表**的那些标签名。
  ///
  /// 口径与详情页原有的提示条**逐条一致**（那是这条规则唯一的旧实现）：
  ///   - 负分标签不算（负分在详情页本来就不展示，commit 6ea90cd），
  ///     拿它当屏蔽依据会凭空多屏蔽一批人；
  ///   - Gay 模式下，与 Gay 词表重叠的标签**不**触发 —— 否则开了 Gay 模式
  ///     之后同一个账号会既被「Gay 模式」放行、又被「屏蔽标签」拦下，
  ///     两条规则互相打架。
  ///
  /// 零分算命中，与旧实现一致（那里判的是 score < 0 才排除）。
  ///
  /// 原来这段逻辑内嵌在 user_detail_screen.dart 里，列表页拿不到；现在收到
  /// 这里，两处共用同一个判定，避免再次各抄一份而漂移。
  static List<String> blockTagHits(Map<String, dynamic> tags) {
    final blocked = getBlockTags().toSet();
    if (blocked.isEmpty) return const [];
    final isGay = isGayMode();
    final hits = <String>[];
    tags.forEach((k, v) {
      if (!blocked.contains(k)) return;
      final score = v is num ? v.toInt() : (int.tryParse('$v') ?? 0);
      if (score < 0) return;
      if (isGay && kGayTags.contains(k)) return;
      hits.add(k);
    });
    return hits;
  }

  /// 用户是否应当从列表中隐藏。**这是唯一权威判定，列表页一律调它。**
  ///
  /// 三条本地规则的合并口径：
  ///   1. 按用户名屏蔽（`block-map`）；
  ///   2. 命中屏蔽标签列表（用户带正权重的屏蔽标签）；
  ///   3. Gay 模式匹配（关闭时排除带 Gay 标签的，开启时只留带 Gay 标签的）。
  ///
  /// 以前这三条是**各屏各抄一份**，于是慢慢漂移：Gay 模式就曾在标签反查页
  /// 整条漏掉（同一个查询换个入口看到不同的用户集合）。把判定收在这里，
  /// 新增列表时只需要调它，不再有机会漏。
  static bool shouldHideUser(String username, Map<String, int> tags) {
    if (isBlocked(username)) return true;
    if (blockTagHits(tags).isNotEmpty) return true;
    return !matchesGayMode(tags);
  }
}

/// 当前生效的 Gay 模式标签集合（动态读取 StorageService.getGayTags）
Set<String> get kGayTags => StorageService.getGayTags().toSet();

/// 默认的 Gay 模式核心标签常量集合。
///
/// 以前这里是**独立写死**的一份，和上面的 `kDefaultGayTags` 内容相同却是两个
/// 定义 —— 改一处忘另一处，两边就悄悄漂移（这正是本项目反复出问题的形态）。
/// 现在改成从唯一的真相源派生，全仓不再有第二份字面量。
///
/// 词表本身见 [kDefaultGayTags] 的注释：它与图站 gallery/static/home.js 的
/// `DEFAULT_GAY_TAGS` 是**同一份跨端契约**，改一处必须同步另一处，并由
/// test/gay_tag_contract_test.dart 把两端字面量钉在一起。
// 注意要写 StorageService.kDefaultGayTags —— kDefaultGayTags 是类里的
// **static 成员**，顶层作用域直接引用会报 undefined_identifier。
final Set<String> kDefaultGayTagsSet =
    StorageService.kDefaultGayTags.toSet();
