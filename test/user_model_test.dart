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

    test('媒体类型判断依据（video/animated_gif 走视频通道）', () {
      const videoTypes = ['video', 'animated_gif'];
      for (final t in videoTypes) {
        final item = TimelineItem.fromJson({'url': 'https://x/f', 'type': t});
        // 与 user_detail_screen._batchDownload 的扩展名规则一致
        final isVideo = t == 'video' || t == 'animated_gif';
        expect(isVideo, videoTypes.contains(item.type));
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
