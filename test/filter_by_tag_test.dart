// 「按标签筛选」的判据测试。
//
// 本文件钉住的每一条都是**可证伪**的行为契约，不是实现细节：
//
//  1) 匹配口径：**只看 `tags` 里的键是否存在，权重符号不参与判定**
//     （`{"COS": -1}` 也算命中 COS）。这条最容易被下一个人"顺手优化"成
//     `weight > 0`，所以单独钉死并给出反例。
//  2) 空选择 = 不过滤，且**原样返回**（不改变顺序、不丢元素）。
//  3) 多选之间是 **OR 并集**。
//  4) 本地隐藏规则（屏蔽 / 屏蔽标签 / Gay 模式）与标签筛选**叠加**生效：
//     同时命中两者时一定被藏掉，且顺序是「先标签、后隐藏」。
//  5) 分页去重会丢掉闭区间锚点重复的那一个（线上 `after` 是闭区间，
//     每翻一页必然重复一个用户，不去重会撞 Duplicate keys）。
//  6) `TagCount` 能吃线上真实的大写键 `Tag`/`Count`，也吃小写 ——
//     Go 那边结构体没写 json tag，按小写取会**静默全空**。
//
// 只测纯函数（filterUsersByTags / matchesTagFilter / applyVisibleRules /
// visibleUsers / dedupeByUsername / TagCount），不发任何真实网络请求。
// 渲染层（_TagFilterBar）依赖真实 api 实例，不值得在这里拉进来；
// 真要测它另开 widget 测试。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/models/user.dart';
import 'package:twitter_pic_flutter/screens/user_list_screen.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';

TwitterUser u(String username, [Map<String, int> tags = const {}]) =>
    TwitterUser(username: username, tags: tags);

/// 本地隐藏规则的替身：只藏 [blocked] 里的用户名 / 带 [blockedTag] 的用户。
bool Function(String, Map<String, int>) hideFn(
  Set<String> blocked,
  String? blockedTag,
) =>
    (username, tags) =>
        blocked.contains(username) || (blockedTag != null && tags.containsKey(blockedTag));

/// StorageService 的假平台实现（规则落盘到临时目录，不碰真实文件系统）。
class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  // 真实 StorageService 的用例需要文件系统（它把规则写进 storage.json）。
  // 用假 path_provider 指向临时目录，setUp/tearDown 成对 resetForTests 隔离 ——
  // 见 block_tag_filter_test.dart：必须 resetForTests 而不是 clearAll，
  // 后者不会把进程级 _loaded 置回 false，单跑绿、整包红。
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('filter_by_tag');
    PathProviderPlatform.instance = _FakePathProvider(tmpDir.path);
    StorageService.resetForTests();
    await StorageService.ensureInitialized();
  });

  tearDown(() async {
    StorageService.resetForTests();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  group('TagCount 解析', () {
    test('吃线上真实的大写键 Tag/Count（按小写取会静默全空）', () {
      final parsed = TagCount.listFromJson([
        {'Tag': '女性', 'Count': 7579},
      ]);
      expect(parsed, hasLength(1));
      expect(parsed.single.tag, '女性');
      expect(parsed.single.count, 7579);
    });

    test('大小写容错：小写 tag/count 同样解析', () {
      final parsed = TagCount.listFromJson([
        {'tag': '露奶', 'count': 15},
      ]);
      expect(parsed.single.tag, '露奶');
      expect(parsed.single.count, 15);
    });

    test('Count 缺失按 0，不抛异常', () {
      final parsed = TagCount.listFromJson([
        {'Tag': '无马'},
      ]);
      expect(parsed.single.count, 0);
    });

    test('丢弃空标签名；非 Map 元素不炸', () {
      final parsed = TagCount.listFromJson([
        {'Tag': '', 'Count': 3},
        'garbage',
        42,
        {'Tag': '自拍', 'Count': 14},
      ]);
      expect(parsed, hasLength(1));
      expect(parsed.single.tag, '自拍');
    });

    test('非 List 输入返回空列表，不抛', () {
      expect(TagCount.listFromJson(null), isEmpty);
      expect(TagCount.listFromJson('nope'), isEmpty);
    });

    test('排序稳定：count 升序，同数按标签名升序', () {
      final parsed = TagCount.listFromJson([
        {'Tag': '大奶', 'Count': 7},
        {'Tag': '二次元', 'Count': 14},
        {'Tag': 'COS', 'Count': 7},
      ]);
      expect(parsed.map((e) => e.tag).toList(), ['COS', '大奶', '二次元']);
    });
  });

  group('权重符号口径', () {
    test('负权也算命中 —— 只看键是否存在', () {
      final user = u('a', {'COS': -1});
      expect(matchesTagFilter(user, 'COS'), isTrue);
    });

    test('权重 0 也算命中', () {
      expect(matchesTagFilter(u('a', {'露奶': 0}), '露奶'), isTrue);
    });

    test('没有这个键就不命中', () {
      expect(matchesTagFilter(u('a', {'COS': 5}), '露奶'), isFalse);
    });

    test('空 tags 永远不命中', () {
      expect(matchesTagFilter(u('a'), 'COS'), isFalse);
    });

    test('hasTagKey / weightOf 与 matchesTagFilter 同口径', () {
      final user = u('a', {'COS': -3});
      expect(user.hasTagKey('COS'), isTrue);
      expect(user.weightOf('COS'), -3);
      expect(user.hasTagKey('自拍'), isFalse);
      expect(user.weightOf('自拍'), isNull,
          reason: '「没有这个标签」要能与「权重为 0」区分开');
    });
  });

  group('filterUsersByTags', () {
    final users = [
      u('alice', {'COS': 5}),
      u('bob', {'自拍': 3}),
      u('carol', {'COS': -2, '露奶': 8}),
      u('dave', {}),
    ];

    test('空选择 = 不过滤，原样返回全部', () {
      final out = filterUsersByTags(users, <String>{});
      expect(out.map((e) => e.username).toList(),
          ['alice', 'bob', 'carol', 'dave']);
    });

    test('单选按键命中，负权用户照样留下', () {
      final out = filterUsersByTags(users, {'COS'});
      expect(out.map((e) => e.username).toList(), ['alice', 'carol']);
    });

    test('多选是 OR 并集', () {
      final out = filterUsersByTags(users, {'COS', '自拍'});
      expect(out.map((e) => e.username).toList(), ['alice', 'bob', 'carol']);
    });

    test('零命中的标签给出空列表（空态由 UI 区分「无结果」）', () {
      expect(filterUsersByTags(users, {'不存在的标签'}), isEmpty);
    });

    test('返回新列表，不改原列表（不引入原地修改）', () {
      final out = filterUsersByTags(users, {'COS'});
      expect(identical(out, users), isFalse);
      expect(users, hasLength(4), reason: '入参不能被就地截断');
    });

    test('空选择时也返回副本而非原引用', () {
      final out = filterUsersByTags(users, <String>{});
      expect(identical(out, users), isFalse);
    });
  });

  group('与本地隐藏规则叠加', () {
    final users = [
      u('alice', {'COS': 5}),
      u('bob', {'COS': 3}),
      u('blockedguy', {'COS': 5}),
    ];

    test('同时命中标签与屏蔽规则 → 被藏掉（隐藏优先）', () {
      final out = visibleUsers(users, {'COS'}, hideFn({'blockedguy'}, null));
      expect(out.map((e) => e.username).toList(), ['alice', 'bob']);
    });

    test('屏蔽标签命中 → 被藏掉', () {
      final out = visibleUsers(users, {'COS'}, hideFn({}, 'COS'));
      expect(out, isEmpty,
          reason: '屏蔽标签是更高优先级的本地规则');
    });

    test('没有选标签时，隐藏规则照样生效', () {
      final out = visibleUsers(users, <String>{}, hideFn({'alice'}, null));
      expect(out.map((e) => e.username).toList(), ['bob', 'blockedguy']);
    });

    test('标签筛选与隐藏规则都不命中任何东西 → 空列表', () {
      final out =
          visibleUsers(users, {'不存在'}, hideFn({'alice', 'bob', 'blockedguy'}, null));
      expect(out, isEmpty);
    });

    test('applyVisibleRules 不改入参顺序', () {
      final input = [u('a'), u('b'), u('c')];
      final out = applyVisibleRules(input, (_, __) => false);
      expect(out.map((e) => e.username).toList(), ['a', 'b', 'c']);
      expect(input, hasLength(3));
    });
  });

  group('分页去重（线上 after 是闭区间）', () {
    test('丢掉与已有列表重复的锚点用户', () {
      final existing = [u('a'), u('b'), u('c')];
      // 线上闭区间：下一页第一项 === 上一页最后一项 'c'。
      final incoming = [u('c'), u('d'), u('e')];
      final out = dedupeByUsername(incoming, existing: existing);
      expect(out.map((e) => e.username).toList(), ['d', 'e']);
    });

    test('同时挡掉新一页内部的重复', () {
      final out = dedupeByUsername([u('x'), u('y'), u('x'), u('z')]);
      expect(out.map((e) => e.username).toList(), ['x', 'y', 'z'],
          reason: '页内重复同样会撞 ValueKey 断言');
    });

    test('空 username 被丢弃', () {
      expect(dedupeByUsername([u(''), u('a')]).map((e) => e.username).toList(),
          ['a']);
    });

    test('existing 为空时退化为页内去重', () {
      expect(dedupeByUsername([u('a'), u('a')]).map((e) => e.username).toList(),
          ['a']);
    });

    test('顺序保持原样（不是 set 顺序）', () {
      final out = dedupeByUsername([u('c'), u('a'), u('b')]);
      expect(out.map((e) => e.username).toList(), ['c', 'a', 'b']);
    });
  });

  // 上面那组用 hideFn 替身，只考察纯函数；这一组走**真实**的
  // StorageService.shouldHideUser，证明标签筛选接上真实规则后仍然成立
  // —— 两套规则互相覆盖时（屏蔽标签恰好就是被筛的那个标签）最容易出问题。
  group('与真实 StorageService 规则叠加', () {
    test('屏蔽标签命中的用户，在标签筛选后仍然被藏掉', () {
      StorageService.setBlockTags(['无关内容']);
      final users = [
        u('alice', {'女性': 5, '无关内容': 2}),
        u('bob', {'女性': 1}),
      ];
      final out = visibleUsers(users, {'女性'}, StorageService.shouldHideUser);
      expect(out.map((e) => e.username).toList(), ['bob'],
          reason: '屏蔽规则优先级高于标签筛选');
    });

    test('按用户名的屏蔽在标签筛选后仍然生效', () {
      StorageService.toggleBlock('alice');
      final out = visibleUsers(
          [u('alice', {'女性': 5}), u('bob', {'女性': 1})],
          {'女性'},
          StorageService.shouldHideUser);
      expect(out.map((e) => e.username).toList(), ['bob']);
    });

    test('Gay 模式开启：只留带 Gay 标签（正权）的用户', () {
      StorageService.setGayMode(true);
      final users = [
        u('alice', {'女性': 1, '男娘': 2}),
        u('bob', {'女性': 1, '男娘': -1}), // 负权：hasGayTag 只认正权
      ];
      final out = visibleUsers(users, {'女性'}, StorageService.shouldHideUser);
      expect(out.map((e) => e.username).toList(), ['alice'],
          reason: 'Gay 模式判据是正权，与筛选的「键存在即命中」是两套口径');
    });

    test('Gay 模式关闭：带 Gay 标签的用户被藏掉', () {
      StorageService.setGayMode(false);
      final out = visibleUsers(
        [u('alice', {'女性': 1}), u('bob', {'女性': 1, '男娘': 2})],
        {'女性'},
        StorageService.shouldHideUser,
      );
      expect(out.map((e) => e.username).toList(), ['alice']);
    });

    test('屏蔽标签为空时不过滤任何人（连坐防护）', () {
      StorageService.setBlockTags([]);
      final out = visibleUsers(
          [u('alice', {'女性': 1})], {'女性'}, StorageService.shouldHideUser);
      expect(out, hasLength(1));
    });
  });
}