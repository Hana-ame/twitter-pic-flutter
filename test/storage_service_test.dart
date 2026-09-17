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
    if (await tmp.exists()) await tmp.delete(recursive: true);
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
      // 原实现 unawaited(writeAsString) 并发交错，可能写坏 storage.json。
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

      // clearAll 必须 await 自己的写盘：返回时磁盘应该是空的。否则设置页
      // 「清除数据」await 完就去改 UI，中途被系统杀进程时旧数据会残留
      // —— 等于没清。
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

      // 模拟进程重启
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

      // 非 Gay 模式下（默认关闭）：
      // 包含 Gay 标签的用户被过滤（false）；不包含的保留（true）
      StorageService.setGayMode(false);
      expect(StorageService.matchesGayMode({'男同': 1}), isFalse);
      expect(StorageService.matchesGayMode({'男性': 1, '自拍': 2}), isFalse);
      expect(StorageService.matchesGayMode({'露屌': 1}), isFalse);
      expect(StorageService.matchesGayMode({'二次元': 1}), isTrue);
      expect(StorageService.matchesGayMode({}), isTrue);

      // Gay 模式下（开启）：
      // 包含 Gay 标签的用户保留（true）；不包含的被过滤（false，正好取反）
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

      // 模拟进程重启
      StorageService.resetForTests();
      await StorageService.ensureInitialized();
      expect(StorageService.getGayTags(), ['男娘', '人妖', '露屌', '阳痿', '男同', '伪娘']);

      // 动态过滤也随之生效
      StorageService.setGayMode(true);
      expect(StorageService.matchesGayMode({'伪娘': 1}), isTrue);
      expect(StorageService.matchesGayMode({'男性': 1}), isFalse);

      // 重置回默认
      StorageService.resetGayTags();
      expect(StorageService.getGayTags(), ['男性', '男娘', '人妖', '露屌', '阳痿', '男同']);
    });
  });
}
