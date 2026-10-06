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

/// 「在用户列表页按某个标签查找」的动作句柄。
///
/// 由 `UserListScreen` 创建并透传给 `UserDetailScreen`；详情页只调用
/// [enter]，不关心数据从哪来、也不自己调 API。
class TagBrowseRequest {
  const TagBrowseRequest(this._onEnter);

  /// 把 [tag] 交给用户列表页处理；返回是否真的切了过去。
  final bool Function(String tag) _onEnter;

  /// 请求按 [tag] 查找（留在用户列表页，不新开页面）。
  ///
  /// [onSwitched] 在**确实切换之后**执行——详情页用它 pop 自己，
  /// 让标签结果正好出现在来源页上。
  bool enter(String tag, {void Function()? onSwitched}) {
    final ok = _onEnter(tag);
    if (ok) onSwitched?.call();
    return ok;
  }

  /// 「什么也不做」的实现，供拿不到用户列表页的调用方（如深链打开的
  /// 详情页）使用。
  ///
  /// 显式给出而不是靠 nullable：读代码时能看见存在兜底路径。页面若因此
  /// 点了标签没反应，**必须显式提示用户**，不能静默。
  static const TagBrowseRequest unavailable = TagBrowseRequest(_neverEnter);

  static bool _neverEnter(String tag) => false;
}

/// 能否就地切标签。配 [TagBrowseRequest.unavailable] 用。
bool canBrowseTagInPlace(TagBrowseRequest? request) =>
    request != null && !identical(request, TagBrowseRequest.unavailable);
