// 「按标签看人」这件事的**跨页面入口**。
//
// 为什么需要它：用户点标签时要**留在同一个页面**（`UserListScreen`），
// 但点标签的地方不止用户列表页——用户详情页的标签区也能点。详情页自己
// `Navigator.push` 一个 `TagUserListScreen` 会跳到独立标签页，于是
// 「看某标签下的人」变成两个页面、两种返回行为，用户要多记一次「我刚才
// 是在哪」——这正是要消除的认知负担。
//
// 所以详情页不自己加载，而是把请求**递回**用户列表页执行。递回而不是各做
// 一份：标签列表在 `UserListScreen` 里已经做全了（全量分页、并集筛选、
// 去重、空/错/加载态），在这里再实现一份，那两处必然各自漂移——
// **同一件事只能有一份实现**，否则修 bug 要修两遍且总会漏掉一处。

/// 「留在来源页按某个标签查找」的动作句柄。
///
/// 由来源页（`UserListScreen`）创建并透传给 `UserDetailScreen`；详情页只
/// 调用它，不关心数据从哪来、也不自己调 API。
///
/// **没有就是 null。** 本文件此前还有一个 `static const unavailable`
/// 哨兵值，配套 `canBrowseTagInPlace()` 用 `identical()` 判定——那是为
/// 「没有这个能力」凭空造出的第二种状态，而生产代码一次都没用过它（全仓
/// 只有测试引用）。「拿不到来源页」和「拿到的句柄拒绝干活」在界面上是
/// 同一件事：都得给用户一句明确反馈。两种状态两个表示法，只是让每个调用
/// 点多一处要记得处理的分支。
///
/// 因此现在只有一个形态：拿到句柄就调，拿不到（null）就提示。
typedef TagBrowseRequest = bool Function(String tag);

/// 「切换确实发生了」的回调。
///
/// 详情页用它 pop 自己，让标签结果正好出现在来源页上；「什么都不做」
/// 由调用方用 null 表达，不需要再单独造一个 no-op 哨兵。
typedef TagBrowseDone = void Function();

/// 把请求递回来源页，返回是否真的切了过去。
///
/// 返回 true = 标签结果**确实出现在来源页上**（调用方可以 pop 详情页）；
/// false = 没切（空标签名、与当前选中重复）——调用方**不该** pop，否则用户被
/// 丢回来源页却看不到任何变化，比不响应更难理解。
///
/// [onDone] 只在**确实切换之后**执行。
bool enterTagInPlace(TagBrowseRequest request, String tag,
    {TagBrowseDone? onDone}) {
  final switched = request(tag);
  if (switched) onDone?.call();
  return switched;
}
