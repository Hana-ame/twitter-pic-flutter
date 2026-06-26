// Twitter 用户模型，包括基本信息和统计
class TwitterUser {
  final String username;
  final String? nick;
  final String? avatar;
  final int? totalUrls;

  TwitterUser({
    required this.username,
    this.nick,
    this.avatar,
    this.totalUrls,
  });

  factory TwitterUser.fromJson(Map<String, dynamic> json) {
    return TwitterUser(
      username: json['username'] as String,
      nick: json['nick'] as String?,
      avatar: json['avatar'] as String?,
      totalUrls: json['total_urls'] as int?,
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
      url: json['url'] as String,
      type: json['type'] as String,
      date: json['date'] as String?,
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
    final info = json['account_info'] as Map<String, dynamic>;
    final tl = json['timeline'] as List<dynamic>;
    return UserMetaData(
      accountInfo: TwitterUser(
        username: info['name'] as String,
        nick: info['nick'] as String?,
        avatar: info['profile_image'] as String?,
        totalUrls: json['total_urls'] as int?,
      ),
      timeline: tl.map((e) => TimelineItem.fromJson(e as Map<String, dynamic>)).toList(),
      totalUrls: json['total_urls'] as int? ?? tl.length,
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
      username: json['username'] as String,
      votes: json['votes'] as int,
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
    return EmojiPeriodData(
      day: (json['day'] as List<dynamic>?)?.map((e) => RankingEntry.fromJson(e)).toList() ?? [],
      week: (json['week'] as List<dynamic>?)?.map((e) => RankingEntry.fromJson(e)).toList() ?? [],
      month: (json['month'] as List<dynamic>?)?.map((e) => RankingEntry.fromJson(e)).toList() ?? [],
    );
  }
}
