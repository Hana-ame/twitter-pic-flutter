// 下载落地文件名：图片必须有后缀、视频哈希必须在扩展名之前。
// 修的是手机上两个手动劳动（issue：自动后缀）：
//   * 图片 `twitter_<hash>_FooBar`（无后缀）→ 相册/文件管理器不认成图片，
//     用户得手动补 .jpg；
//   * 视频 `xyz.mp4-<hash>`（扩展名变成 .mp4-<hash>）→ 系统不认成视频，
//     用户得手动删多余后缀。
//
// 纯函数，无 StorageService / 网络，不触发存储闸门。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/services/video_downloader.dart';
import 'package:twitter_pic_flutter/utils/download_name.dart';

void main() {
  group('imageTempFileName：图片临时文件名必带正确后缀', () {
    test('twimg 图片（format=jpg）→ .jpg，且保留 URL 末段作可读部分', () {
      final name = imageTempFileName(
          'https://pbs.twimg.com/media/HRHinAZa8AA7G2D?format=jpg&name=orig');
      expect(name, startsWith('twitter_'));
      expect(name, contains('HRHinAZa8AA7G2D'));
      expect(name, endsWith('.jpg'));
    });

    test('format=png → .png（不再一律 .jpg）', () {
      expect(imageTempFileName('https://pbs.twimg.com/media/X?format=png'),
          endsWith('.png'));
    });

    test('响应 Content-Type 优先于 URL 推导', () {
      final name = imageTempFileName('https://pbs.twimg.com/media/X?format=jpg',
          contentType: 'image/png');
      expect(name, endsWith('.png'));
    });

    test('路径末段已带已知扩展名时不重复追加', () {
      final name = imageTempFileName(
          'https://pbs.twimg.com/profile_images/1/avatar_normal.jpg');
      expect(name, endsWith('avatar_normal.jpg'));
      expect(name.endsWith('.jpg.jpg'), isFalse);
    });

    test('什么都推不出时兜底 .jpg', () {
      expect(imageTempFileName('https://pbs.twimg.com/media/X'), endsWith('.jpg'));
    });

    test('同 URL 两次生成一致（哈希稳定）', () {
      const url = 'https://pbs.twimg.com/media/X?format=jpg&name=orig';
      expect(imageTempFileName(url), imageTempFileName(url));
    });
  });

  group('videoTempFileName：视频哈希必须在扩展名之前', () {
    test('twimg 视频 → <stem>-<hash>.mp4，不再是 .mp4-<hash>', () {
      final name = videoTempFileName(
          'https://video.twimg.com/amplify_video/1/vid/avc1/720x720/x.mp4?tag=29');
      expect(name, endsWith('.mp4'));
      expect(RegExp(r'\.mp4-[0-9a-f]+$').hasMatch(name), isFalse,
          reason: '哈希不能拼在扩展名后面：$name');
      expect(RegExp(r'-([0-9a-f]{16})\.mp4$').hasMatch(name), isTrue,
          reason: '16 位稳定哈希应位于扩展名之前：$name');
    });

    test('无查询参数的视频 URL 同样处理', () {
      final name = videoTempFileName(
          'https://video.twimg.com/amplify_video/1/vid/avc1/720x1280/x.mp4');
      expect(name, endsWith('.mp4'));
    });

    test('路径末段无扩展名时兜底 .mp4', () {
      expect(videoTempFileName('https://video.twimg.com/amplify_video/1/vid/xyz'),
          endsWith('.mp4'));
    });
  });

  group('VideoDownloader.cleanExpiredTempFiles：清理过期分享临时文件', () {
    test('仅清理匹配命名规则且已过期的临时文件，保留新鲜文件与无关文件', () async {
      final tmp = await Directory.systemTemp.createTemp('clean_temp_test');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      final oldImg = File(
        '${tmp.path}/${imageTempFileName("https://pbs.twimg.com/media/A?format=jpg")}',
      );
      final oldVid = File(
        '${tmp.path}/${videoTempFileName("https://video.twimg.com/ext/1/x.mp4")}',
      );
      final freshVid = File(
        '${tmp.path}/${videoTempFileName("https://video.twimg.com/ext/2/y.mp4")}',
      );
      final unrelated = File('${tmp.path}/other_system_file.txt');

      await oldImg.writeAsBytes([1, 2, 3]);
      await oldVid.writeAsBytes([4, 5, 6]);
      await freshVid.writeAsBytes([7, 8, 9]);
      await unrelated.writeAsString('keep me');

      final past = DateTime.now().subtract(const Duration(hours: 30));
      oldImg.setLastModifiedSync(past);
      oldVid.setLastModifiedSync(past);

      final deleted = await VideoDownloader.cleanExpiredTempFiles(
        maxAge: const Duration(hours: 24),
        tempDir: tmp,
      );

      expect(deleted, 2);
      expect(await oldImg.exists(), isFalse);
      expect(await oldVid.exists(), isFalse);
      expect(await freshVid.exists(), isTrue);
      expect(await unrelated.exists(), isTrue);
    });
  });
}
