// feed_state.dart
// 媒体流状态机：使用 Dart 3 sealed class 建模，
// 避免 isLoading/isError/isBottom 等散乱布尔值导致的非法中间状态。
//
// 用法：
//   switch (state) {
//     case FeedLoading(): ...
//     case FeedSuccess(): ...
//     case FeedError(): ...
//   }
//
// 模式匹配确保穷举所有状态，编译器会报错如果遗漏分支。

import 'models/user.dart';

/// 媒体流状态（密封类，子类不可扩展）。
sealed class FeedState {
  const FeedState();
}

/// 加载中（首次或分页）。
class FeedLoading extends FeedState {
  /// 是否为分页加载（追加），而非首次加载。
  final bool isPaginating;
  const FeedLoading({this.isPaginating = false});
}

/// 加载成功，含当前数据与分页标记。
class FeedSuccess extends FeedState {
  final List<TimelineItem> items;
  final bool hasMore;
  const FeedSuccess(this.items, {this.hasMore = true});
}

/// 加载失败，含错误信息。
class FeedError extends FeedState {
  final String message;
  const FeedError(this.message);
}

/// 空状态：无数据（后端返回空列表）。
class FeedEmpty extends FeedState {
  const FeedEmpty();
}

/// 用户详情页的完整状态：包含媒体流 + 标签 + 表情计数。
sealed class DetailState {
  const DetailState();
}

class DetailLoading extends DetailState {
  const DetailLoading();
}

class DetailSuccess extends DetailState {
  final UserMetaData profile;
  final Map<String, dynamic> tags;
  final Map<String, int> emojiCounts;
  const DetailSuccess({
    required this.profile,
    this.tags = const {},
    this.emojiCounts = const {},
  });
}

class DetailError extends DetailState {
  final String message;
  const DetailError(this.message);
}
