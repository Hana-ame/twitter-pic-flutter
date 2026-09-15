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
      // tags 是后加字段：老响应没有它时必须回空 Map，不能是 null。
      expect(minimal.tags, isEmpty);
    });

    test('tags 正常解析（[]User 同构响应，含新版 by=tag 携带的权重）', () {
      final u = TwitterUser.fromJson({
        'username': 'alice',
        'tags': {'女性': 5, '自拍': 3},
      });
      expect(u.tags, {'女性': 5, '自拍': 3});
    });

    test('tags 缺失 / null / 默认构造均为空 Map', () {
      expect(TwitterUser.fromJson({'username': 'x'}).tags, isEmpty);
      expect(TwitterUser.fromJson({'username': 'x', 'tags': null}).tags,
          isEmpty);
      expect(TwitterUser(username: 'x').tags, isEmpty);
    });

    test('tags 非 Map 类型一律回退空 Map，不抛异常', () {
      for (final bad in <dynamic>['女性', 5, 1.5, ['女性'], <String>[], true]) {
        expect(
          TwitterUser.fromJson({'username': 'x', 'tags': bad}).tags,
          isEmpty,
          reason: 'tags=$bad (${bad.runtimeType}) 不应崩溃',
        );
      }
    });

    test('tags 值：字符串数兼容、负数与 0 保留、解析失败兜 0、键不丢', () {
      // 契约：服务端把权重归一到 ±1 累加，库里可能存负值，且目前不过滤 0；
      // Dio/JSON 数字形态不完全可信（int/double/字符串都出现过）。
      final u = TwitterUser.fromJson({
        'username': 'x',
        'tags': {
          '自拍': '3',
          'COS': -1,
          '零': 0,
          '浮点': 2.7,
          '坏值': 'x',
          '空值': null,
        },
      });
      expect(u.tags['自拍'], 3, reason: '字符串数字要能解析');
      expect(u.tags['COS'], -1, reason: '负权重合法，必须原样保留');
      expect(u.tags['零'], 0, reason: '服务端不过滤 0，客户端也不丢');
      expect(u.tags['浮点'], 2, reason: 'num 走 toInt 容错');
      expect(u.tags['坏值'], 0, reason: '解析不出的值兜底 0 而非崩溃/丢键');
      expect(u.tags['空值'], 0);
      expect(u.tags.length, 6);
    });

    test('UserMetaData.accountInfo 无 tags 字段，保持默认空 Map', () {
      // account_info 是 Twitter 侧资料（name/nick/profile_image），标签不在
      // 其中；确认手动构造路径吃到 tags 的默认值。
      final meta = UserMetaData.fromJson({
        'account_info': {'name': 'u1'},
      });
      expect(meta.accountInfo.tags, isEmpty);
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
