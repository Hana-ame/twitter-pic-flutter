import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/models/user.dart';

void main() {
  group('UserMetaData.fromJson', () {
    test('完整字段解析', () {
      final meta = UserMetaData.fromJson({
        'account_info': {
          'name': 'some_user',
          'nick': '昵称',
          'profile_image': 'https://pbs.twimg.com/profile.jpg',
        },
        'total_urls': 42,
        'timeline': [
          {'url': 'https://pbs.twimg.com/media/a.jpg', 'type': 'photo', 'date': '2024-01-01'},
          {'url': 'https://video-cf.twimg.com/b.mp4', 'type': 'video'},
        ],
      });

      expect(meta.accountInfo.username, 'some_user');
      expect(meta.accountInfo.nick, '昵称');
      expect(meta.accountInfo.avatar, 'https://pbs.twimg.com/profile.jpg');
      expect(meta.totalUrls, 42);
      expect(meta.timeline.length, 2);
      expect(meta.timeline[0].type, 'photo');
      expect(meta.timeline[0].date, '2024-01-01');
      expect(meta.timeline[1].date, isNull);
    });

    test('total_urls 缺失时回退为 timeline 长度', () {
      final meta = UserMetaData.fromJson({
        'account_info': {'name': 'u1', 'nick': null, 'profile_image': null},
        'timeline': [
          {'url': 'https://x/1.jpg', 'type': 'photo'},
          {'url': 'https://x/2.gif', 'type': 'animated_gif'},
          {'url': 'https://x/3.mp4', 'type': 'video'},
        ],
      });
      expect(meta.totalUrls, 3);
    });

    test('TimelineItem.type 原样透传，视频通道判定按真实值', () {
      // 这条测试的原写法是 `isVideo == videoTypes.contains(item.type)`，
      // 而 isVideo 本身就是用同一个 t 算出来的 —— 同义反复，把 fromJson
      // 改坏（比如永远返回 'photo'）也会照样过。
      const cases = {
        'video': true,
        'animated_gif': true,
        'photo': false,
        'unknown_type': false,
      };
      for (final entry in cases.entries) {
        final item = TimelineItem.fromJson(
            {'url': 'https://x/f', 'type': entry.key});
        expect(item.type, entry.key,
            reason: 'type 必须从 JSON 原样透传，不能被改写或丢弃');
        // 与 user_detail_screen._batchDownload 的分流规则一致：
        // 视频/动图走视频下载通道，其余走图片通道。
        final isVideo = item.type == 'video' || item.type == 'animated_gif';
        expect(isVideo, entry.value, reason: entry.key);
      }
    });
  });

  group('TwitterUser.fromJson', () {
    test('解析与空值容忍', () {
      final u = TwitterUser.fromJson({
        'username': 'abc',
        'nick': 'ABC',
        'avatar': 'https://a.png',
        'total_urls': 7,
      });
      expect(u.username, 'abc');
      expect(u.totalUrls, 7);

      final minimal = TwitterUser.fromJson({'username': 'x'});
      expect(minimal.nick, isNull);
      expect(minimal.totalUrls, isNull);
    });
  });

  group('EmojiPeriodData.fromJson', () {
    test('缺失周期回退为空列表', () {
      final d = EmojiPeriodData.fromJson({
        'day': [
          {'username': 'u', 'votes': 3},
        ],
      });
      expect(d.day.length, 1);
      expect(d.day.first.votes, 3);
      expect(d.week, isEmpty);
      expect(d.month, isEmpty);
    });
  });
}
