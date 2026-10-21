// media_saver_and_timeline_filter_test.dart
// 测试：
//   1. MediaSaver 文件名防碰撞生成与流式下载落盘（含失败自动删半截文件）；
//   2. UserDetailScreen 的 filterAndSortTimeline 媒体类型筛选与正序/倒序排序。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/models/user.dart';
import 'package:twitter_pic_flutter/screens/user_detail_screen.dart';
import 'package:twitter_pic_flutter/services/media_saver.dart';

void main() {
  group('MediaSaver.buildFileName', () {
    test('不同路径下同名 1.jpg 生成不同文件名（含稳定哈希后缀，防互相覆盖）', () {
      const urlA = 'https://pbs.twimg.com/media/aaa/1.jpg?format=jpg&name=orig';
      const urlB = 'https://pbs.twimg.com/media/bbb/1.jpg?format=jpg&name=orig';

      final nameA = MediaSaver.buildFileName(urlA, username: 'alice');
      final nameB = MediaSaver.buildFileName(urlB, username: 'alice');

      expect(nameA, isNot(equals(nameB)));
      expect(nameA, startsWith('alice_1_'));
      expect(nameA, endsWith('.jpg'));
    });

    test('按 URL 参数推断图片扩展名，视频固定 .mp4', () {
      expect(
        MediaSaver.buildFileName(
          'https://pbs.twimg.com/media/Abc123?format=png&name=orig',
        ),
        endsWith('.png'),
      );
      expect(
        MediaSaver.buildFileName(
          'https://video.twimg.com/ext_tw_video/999/pu/vid/720x1280/v.mp4?tag=12',
          username: '@bob',
          isVideo: true,
        ),
         allOf(startsWith('bob_v_'), endsWith('.mp4')),
      );
    });
  });

  group('MediaSaver.saveToDownloads（本地回环流式保存）', () {
    late Directory tmpDir;
    late HttpServer server;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('media_saver_test');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    test('HTTP 200 时流式写入目标文件夹且字节完整', () async {
      final payload = List<int>.generate(1024, (i) => i & 0xff);
      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.add(payload);
        await req.response.close();
      });

      final proxied = Uri.parse('http://127.0.0.1:${server.port}/media/pic.jpg');
      final saved = await MediaSaver.saveToDownloads(
        proxiedUri: proxied,
        originalUrl: 'https://pbs.twimg.com/media/pic.jpg?format=jpg&name=orig',
        username: 'alice',
        baseDirOverride: tmpDir,
      );

      expect(await saved.exists(), isTrue);
      expect(await saved.readAsBytes(), equals(payload));
      expect(saved.parent.path, endsWith('alice'));
    });

    test('HTTP 非 200 时抛错且不残留空文件或半截文件', () async {
      server.listen((req) async {
        req.response.statusCode = 404;
        await req.response.close();
      });

      final proxied = Uri.parse('http://127.0.0.1:${server.port}/media/missing.jpg');
      await expectLater(
        MediaSaver.saveToDownloads(
          proxiedUri: proxied,
          originalUrl: 'https://pbs.twimg.com/media/missing.jpg',
          username: 'alice',
          baseDirOverride: tmpDir,
        ),
        throwsA(isA<HttpException>()),
      );

      final userDir = Directory('${tmpDir.path}${Platform.pathSeparator}alice');
      if (await userDir.exists()) {
        expect(userDir.listSync(), isEmpty,
            reason: '下载失败不得在目标目录留下 0 字节或半截文件');
      }
    });
  });

  group('filterAndSortTimeline（详情页媒体筛选与排序）', () {
    final items = <TimelineItem>[
      TimelineItem(url: 'https://pbs.twimg.com/media/p1.jpg', type: 'photo', date: '2026-10-03'),
      TimelineItem(url: 'https://video.twimg.com/v1.mp4', type: 'video', date: '2026-10-02'),
      TimelineItem(url: 'https://video.twimg.com/g1.mp4', type: 'animated_gif', date: '2026-10-01'),
      TimelineItem(url: 'https://pbs.twimg.com/media/p2.jpg', type: 'photo', date: '2026-09-30'),
    ];

    test('全部 / 仅图片 / 仅视频筛选准确', () {
      final all = filterAndSortTimeline(items, filter: MediaFilter.all);
      expect(all.length, 4);

      final photos = filterAndSortTimeline(items, filter: MediaFilter.photo);
      expect(photos.map((e) => e.url).toList(), [
        'https://pbs.twimg.com/media/p1.jpg',
        'https://pbs.twimg.com/media/p2.jpg',
      ]);

      final videos = filterAndSortTimeline(items, filter: MediaFilter.video);
      expect(videos.map((e) => e.url).toList(), [
        'https://video.twimg.com/v1.mp4',
        'https://video.twimg.com/g1.mp4',
      ]);
    });

    test('oldestFirst 为 true 时逆序排列且不修改原列表', () {
      final reversed = filterAndSortTimeline(
        items,
        filter: MediaFilter.photo,
        oldestFirst: true,
      );
      expect(reversed.map((e) => e.url).toList(), [
        'https://pbs.twimg.com/media/p2.jpg',
        'https://pbs.twimg.com/media/p1.jpg',
      ]);
      // 原列表顺序不变
      expect(items.first.url, 'https://pbs.twimg.com/media/p1.jpg');
    });
  });
}
