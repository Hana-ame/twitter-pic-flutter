// 标签推荐：把「输入框里打的字」和「全站标签表」匹配，排出一个可点的候选列表。
//
// **为什么推荐是纯客户端的**：`/api/tag-cloud?limit=500` 一次就能把全站标签表
// 拉回来（实测 178 个标签、约 5 KB），标签名没有分页、没有游标、也**没有**
// 服务端搜索端点。所以推荐这件事不需要新 API：拿到标签表后在本地匹配就够，
// 而且离线/标签表已缓存时推荐立刻可用（0 次网络往返）。
//
// 匹配规则刻意分成两档（见 [rankTagSuggestions]）：
//   - **前缀命中**：打「女」先出「女性」，打「二」先出「二次元」；
//   - **子串命中**：打「性」也能出「女性」「男女性交」。
// 只做子串会丢掉前缀（子串里子串位置乱序会挤掉最像的那个），只做前缀则
// 「打个中间字就找不到」——中文标签里中间字是很自然的输入方式。

import '../models/user.dart';

/// 推荐候选最多给多少个。
///
/// 上限而非全量：标签表 178 条，逐条铺开会把搜索框底下整屏糊住，用户反而
/// 找不到想点的那一个。8 条是「一眼扫完、不用滚」的数量级。
const int kTagSuggestLimit = 8;

/// 在 [cloud] 里找与 [query] 匹配的标签，按匹配质量降序返回（最多 [limit] 个）。
///
/// 排序键（同键内按标签名升序，保证结果稳定不抖——同样的输入必须给同样的
/// 顺序，否则用户两次输入同一个词会看到不同的候选）：
///  1. 前缀命中（`女性`.startsWith(`女`)）排在子串命中之前；
///  2. 匹配到的位置越靠前越好（`女性` 对「性」在 index 1，比
///     `性感` 的 index 0 稍差——中文里靠前的字通常更接近标签的主干）；
///  3. 同档同位置时，**人数多的在前**（[TagCount.count] 是人数口径）。
///
/// 空 [query] 返回**人数最多的热门标签**（最多 [limit] 个）——这是本次改动的
/// 关键：既然不再要求用户打 `#`，那么用户**刚点进搜索框、一个字还没打**时就该
/// 看到点什么，否则推荐功能等于要用户先想好标签名才生效，那还是「记得住 `#`
/// 才用得了」的同一个毛病，只是换了个符号。
///
/// 大小写不敏感：标签表里有 COS / cosplay 这类拉丁字母标签，用户按习惯
/// 可能打小写。中文没有大小写，统一 `toLowerCase` 不影响它们。
List<TagCount> rankTagSuggestions(
  List<TagCount> cloud,
  String query, {
  int limit = kTagSuggestLimit,
}) {
  if (limit <= 0) return const <TagCount>[];
  final q = query.trim().toLowerCase();

  if (q.isEmpty) {
    // 空查询 = 「我还没想好要找什么」→ 给热门榜当起手。复用同一份标签表、
    // 同一个上限，不新增状态。
    // 排序走副本：不能就地改调用方持有的标签表（那个 List 会被
    // UserListScreen 直接拿去渲染标签栏，就地排序会让搜索框的排序
    // 漏到标签栏上，两处顺序互相污染）。
    final hot = List<TagCount>.of(cloud)
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.tag.compareTo(b.tag);
      });
    return hot.take(limit).toList(growable: false);
  }

  final hits = <({TagCount item, bool prefix, int at})>[];
  for (final item in cloud) {
    final lower = item.tag.toLowerCase();
    if (lower.startsWith(q)) {
      hits.add((item: item, prefix: true, at: 0));
    } else {
      final at = lower.indexOf(q);
      if (at >= 0) hits.add((item: item, prefix: false, at: at));
    }
  }

  hits.sort((a, b) {
    // 1) 前缀命中优先于子串命中。
    if (a.prefix != b.prefix) return a.prefix ? -1 : 1;
    // 2) 同一档内，匹配位置越靠前越好。
    if (a.at != b.at) return a.at.compareTo(b.at);
    // 3) 再看人数；人数相同按标签名，保证稳定不抖。
    final byCount = b.item.count.compareTo(a.item.count);
    return byCount != 0 ? byCount : a.item.tag.compareTo(b.item.tag);
  });

  return hits.take(limit).map((h) => h.item).toList(growable: false);
}