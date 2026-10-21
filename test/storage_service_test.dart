import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('storage_service_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    StorageService.resetForTests();
    await StorageService.ensureInitialized();
  });

  tearDown(() async {
    StorageService.resetForTests();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // 已经不在了：正是我们要的结果。
    }
  });

  group('StorageService（storage.json 持久化）', () {
    test('写入落盘：重置内存后能重新读回', () async {
      StorageService.toggleFav('user_a');
      await StorageService.debugFlushPending();

      // 模拟进程重启
      StorageService.resetForTests();
      await StorageService.ensureInitialized();

      expect(StorageService.isFav('user_a'), isTrue);
      expect(StorageService.isFav('user_b'), isFalse);
    });

    test('toggle 幂等切换', () {
      expect(StorageService.isFav('u'), isFalse);
      StorageService.toggleFav('u');
      expect(StorageService.isFav('u'), isTrue);
      StorageService.toggleFav('u');
      expect(StorageService.isFav('u'), isFalse);
    });

    test('快速连续写不损坏文件（串行化 flush 链）', () async {
      for (var i = 0; i < 50; i++) {
        StorageService.toggleFav('user_$i');
      }
      await StorageService.debugFlushPending();

      final content = await File('${tmp.path}/storage.json').readAsString();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final favs = jsonDecode(decoded['fav-map'] as String) as Map<String, dynamic>;
      expect(favs.length, 50);
    });

    test('clearAll 返回时磁盘也已清空', () async {
      StorageService.toggleFav('keep_me');
      StorageService.setCustomTags(['t1']);
      await StorageService.debugFlushPending();

      await StorageService.clearAll();

      expect(StorageService.isFav('keep_me'), isFalse);
      expect(StorageService.getCustomTags(), isEmpty);

      // 模拟进程重启后磁盘上也没有残留
      StorageService.resetForTests();
      await StorageService.ensureInitialized();
      expect(StorageService.isFav('keep_me'), isFalse);
      expect(StorageService.getCustomTags(), isEmpty);
    });

    test('写盘完成后无 .tmp 残留（原子替换）', () async {
      StorageService.setCustomTags(['a', 'b']);
      await StorageService.debugFlushPending();
      final files = tmp.listSync().map((e) => e.path).toList();
      expect(files.any((p) => p.endsWith('.tmp')), isFalse,
          reason: 'files=$files');
    });

    test('高亮/屏蔽标签规则 roundtrip', () async {
      StorageService.setHighlightTags(['二次元', 'COS']);
      StorageService.setBlockTags(['无关内容']);
      await StorageService.debugFlushPending();

      StorageService.resetForTests();
      await StorageService.ensureInitialized();

      expect(StorageService.getHighlightTags(), ['二次元', 'COS']);
      expect(StorageService.getBlockTags(), ['无关内容']);
    });

    test('自定义标签（标签弹窗添加的）持久化', () async {
      StorageService.setCustomTags(['我的自定义tag']);
      await StorageService.debugFlushPending();

      StorageService.resetForTests();
      await StorageService.ensureInitialized();

      expect(StorageService.getCustomTags(), ['我的自定义tag']);
    });

    test('Gay 模式：默认关闭、持久化与切换', () async {
      expect(StorageService.isGayMode(), isFalse);

      final next = StorageService.toggleGayMode();
      expect(next, isTrue);
      expect(StorageService.isGayMode(), isTrue);

      await StorageService.debugFlushPending();

      StorageService.resetForTests();
      await StorageService.ensureInitialized();
      expect(StorageService.isGayMode(), isTrue);

      StorageService.setGayMode(false);
      expect(StorageService.isGayMode(), isFalse);

      await StorageService.debugFlushPending();
      StorageService.resetForTests();
      await StorageService.ensureInitialized();
      expect(StorageService.isGayMode(), isFalse);
    });

    test('clearAll 重置 Gay 模式为默认关闭', () async {
      StorageService.setGayMode(true);
      expect(StorageService.isGayMode(), isTrue);

      await StorageService.clearAll();
      expect(StorageService.isGayMode(), isFalse);

      StorageService.resetForTests();
      await StorageService.ensureInitialized();
      expect(StorageService.isGayMode(), isFalse);
    });

    test('hasGayTag 与 matchesGayMode（正好取反）', () {
      expect(StorageService.hasGayTag({'男同': 1, '二次元': 2}), isTrue);
      expect(StorageService.hasGayTag({'男性': 2}), isTrue);
      expect(StorageService.hasGayTag({'露屌': 1}), isTrue);
      expect(StorageService.hasGayTag({'二次元': 2, '自拍': 1}), isFalse);
      expect(StorageService.hasGayTag({}), isFalse);

      StorageService.setGayMode(false);
      expect(StorageService.matchesGayMode({'男同': 1}), isFalse);
      expect(StorageService.matchesGayMode({'男性': 1, '自拍': 2}), isFalse);
      expect(StorageService.matchesGayMode({'露屌': 1}), isFalse);
      expect(StorageService.matchesGayMode({'二次元': 1}), isTrue);
      expect(StorageService.matchesGayMode({}), isTrue);

      StorageService.setGayMode(true);
      expect(StorageService.matchesGayMode({'男同': 1}), isTrue);
      expect(StorageService.matchesGayMode({'男性': 1, '自拍': 2}), isTrue);
      expect(StorageService.matchesGayMode({'露屌': 1}), isTrue);
      expect(StorageService.matchesGayMode({'二次元': 1}), isFalse);
      expect(StorageService.matchesGayMode({}), isFalse);
    });

    test('Gay 标签列表可配置性、持久化与复位', () async {
      expect(StorageService.getGayTags(), ['男性', '男娘', '人妖', '露屌', '阳痿', '男同']);

      StorageService.addGayTag('伪娘');
      expect(StorageService.getGayTags(), ['男性', '男娘', '人妖', '露屌', '阳痿', '男同', '伪娘']);

      StorageService.removeGayTag('男性');
      expect(StorageService.getGayTags(), ['男娘', '人妖', '露屌', '阳痿', '男同', '伪娘']);

      await StorageService.debugFlushPending();

      StorageService.resetForTests();
      await StorageService.ensureInitialized();
      expect(StorageService.getGayTags(), ['男娘', '人妖', '露屌', '阳痿', '男同', '伪娘']);

      StorageService.setGayMode(true);
      expect(StorageService.matchesGayMode({'伪娘': 1}), isTrue);
      expect(StorageService.matchesGayMode({'男性': 1}), isFalse);

      StorageService.resetGayTags();
      expect(StorageService.getGayTags(), ['男性', '男娘', '人妖', '露屌', '阳痿', '男同']);
    });

    test('已屏蔽账号管理：添加（剥除前导 @）、排序、移除与清空', () async {
      expect(StorageService.getBlockedUsers(), isEmpty);

      StorageService.addBlockedUser(' @charlie ');
      StorageService.addBlockedUser('alice');
      StorageService.addBlockedUser('@@bob');

      expect(StorageService.getBlockedUsers(), ['alice', 'bob', 'charlie']);
      expect(StorageService.isBlocked('charlie'), isTrue);

      StorageService.removeBlockedUser('@bob');
      expect(StorageService.getBlockedUsers(), ['alice', 'charlie']);
      expect(StorageService.isBlocked('bob'), isFalse);

      await StorageService.debugFlushPending();
      StorageService.resetForTests();
      await StorageService.ensureInitialized();
      expect(StorageService.getBlockedUsers(), ['alice', 'charlie']);

      StorageService.clearBlockedUsers();
      expect(StorageService.getBlockedUsers(), isEmpty);
    });

    test('浏览历史：记录、去重提升、保留旧昵称头像、上限截断与持久化', () async {
      expect(StorageService.getBrowseHistory(), isEmpty);

      StorageService.addBrowseHistory(
        '@alice',
        nick: 'Alice',
        avatar: 'https://pbs.twimg.com/a.jpg',
        visitedAtMs: 1000,
      );
      StorageService.addBrowseHistory(
        'bob',
        nick: 'Bob',
        visitedAtMs: 2000,
      );
      // 再次访问 alice（未传 nick/avatar 时应保留之前已知的 nick/avatar 并置顶）
      StorageService.addBrowseHistory(
        'alice',
        visitedAtMs: 3000,
      );

      final list = StorageService.getBrowseHistory();
      expect(list.length, 2);
      expect(list[0].username, 'alice');
      expect(list[0].nick, 'Alice');
      expect(list[0].avatar, 'https://pbs.twimg.com/a.jpg');
      expect(list[0].visitedAtMs, 3000);
      expect(list[1].username, 'bob');

      await StorageService.debugFlushPending();
      StorageService.resetForTests();
      await StorageService.ensureInitialized();

      final reloaded = StorageService.getBrowseHistory();
      expect(reloaded.map((e) => e.username).toList(), ['alice', 'bob']);

      StorageService.removeBrowseHistory('alice');
      expect(
        StorageService.getBrowseHistory().map((e) => e.username).toList(),
        ['bob'],
      );

      // 验证上限 50 条截断
      for (var i = 0; i < 60; i++) {
        StorageService.addBrowseHistory('u_$i', visitedAtMs: 4000 + i);
      }
      final capped = StorageService.getBrowseHistory();
      expect(capped.length, StorageService.maxBrowseHistory);
      expect(capped.first.username, 'u_59');

      StorageService.clearBrowseHistory();
      expect(StorageService.getBrowseHistory(), isEmpty);
    });

    test('外观主题模式：默认 light、切换 dark/system 及非法值兜底', () async {
      expect(StorageService.getThemeMode(), 'light');

      StorageService.setThemeMode('dark');
      expect(StorageService.getThemeMode(), 'dark');

      await StorageService.debugFlushPending();
      StorageService.resetForTests();
      await StorageService.ensureInitialized();
      expect(StorageService.getThemeMode(), 'dark');

      StorageService.setThemeMode('system');
      expect(StorageService.getThemeMode(), 'system');

      StorageService.setThemeMode('invalid_mode');
      expect(StorageService.getThemeMode(), 'light');
    });
  });
}
