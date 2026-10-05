// 搜索框标签推荐下拉 + 「点标签立即进入 tag 查找模式」的渲染判据。
//
// ## 交互契约（本次改动的核心）
//
// **用户不需要输入 `#`。** 输入框里打什么都在拿标签表匹配，打 `#` 只是
// 老写法、仍然被接受。判据必须钉住这一点，否则很容易「改回去」而不自知——
// 单看「打 # 能搜到 tag」这类用例，删掉 `#` 支持后**依然全绿**。
//
// ## 为什么全程用 pump() 而不是 pumpAndSettle()
//
// 输入框一旦获得焦点，光标闪烁就是一个**永不停歇**的动画，pumpAndSettle()
// 会一直等到 10 分钟超时（CI run 37323158057 实测：整包 16m51s，1 例红）。
// 本组件的每一处 setState 都是**同步**的（没有 setState 里 await 网络），
// 所以固定 pump 一次就够了。
//
// ⚠️ `tester.testTextInput.receiveAction(...)` 也必须不碰：它会走到
// `_onSubmitted` → `StorageService.saveSearchHistory` → `unawaited(_flush())`，
// 在整包跑（32 个测试文件共用静态状态）时把整包拖到 10 分钟超时。判「有没有
// 历史」改成直接断言 UI，不靠提交动作。
//
// ## 这组测试拦的是什么
//
// 症状类只有一条：**点了推荐标签，列表没换**。它很难被肉眼抓住，因为推荐下拉
// 本身渲染正常、标签表也正常，只有「点下去之后走哪条数据路」错了。所以判据必须
// 落在**回调收到的标签名**与**回填进输入框的文本**上，而不是下拉看起来对不对。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/models/user.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';
import 'package:twitter_pic_flutter/widgets/search_bar.dart';

/// 一张贴近线上真实形状的标签表（实测 /api/tag-cloud?limit=500 → 178 个标签，
/// 这里取热门那几个）。
final cloud = <TagCount>[
  const TagCount(tag: '女性', count: 7580),
  const TagCount(tag: '男女性交', count: 1554),
  const TagCount(tag: '二次元', count: 1456),
  const TagCount(tag: '自拍', count: 1196),
];

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('不输入 # 也能搜标签', () {
    testWidgets('直接打「女」就出标签候选', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '女');
      await tester.pump();

      expect(find.text('标签推荐'), findsOneWidget);
      expect(find.text('女性'), findsOneWidget);
      expect(find.text('男女性交'), findsOneWidget);
    });

    testWidgets('候选行不带 #（符号不该再出现在界面上）', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '女');
      await tester.pump();

      expect(find.text('#女性'), findsNothing);
      expect(find.text('#男女性交'), findsNothing);
    });

    testWidgets('打 # 仍然能搜（老写法不破坏）', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '#女');
      await tester.pump();

      expect(find.text('标签推荐'), findsOneWidget);
      expect(find.text('女性'), findsOneWidget);
      // '#' 只是被剥掉的前缀，不该作为匹配内容参与匹配。
      expect(find.text('#女'), findsNothing);
    });

    testWidgets('输入框空着时给热门标签当起手', (tester) async {
      // 既然不用打 #，用户刚点进搜索框就该看到点什么；否则推荐等于要用户
      // 先想好标签名才生效。
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(find.text('标签推荐'), findsOneWidget);
      expect(find.text('女性'), findsOneWidget);
    });

    testWidgets('一个都没命中时不弹空框（不假装还能搜）', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'zzz不存在');
      await tester.pump();

      expect(find.text('标签推荐'), findsNothing);
    });

    testWidgets('不传 onPickTag 就不弹推荐（调用方不想要这个功能）',
        (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '女');
      await tester.pump();

      expect(find.text('标签推荐'), findsNothing);
    });

    testWidgets('标签表为空时不弹推荐（标签云还没回来）', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: const <TagCount>[],
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '女');
      await tester.pump();

      expect(find.text('标签推荐'), findsNothing);
    });

    testWidgets('标签表异步到货后，已经打好的词立刻开始推荐', (tester) async {
      // 真实时序：标签云是异步请求回来的，用户很可能在它回来之前就开始打字。
      // 若没有 didUpdateWidget 重算，那种时序下推荐面板**永远不出现**。
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: const <TagCount>[],
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '女');
      await tester.pump();
      expect(find.text('标签推荐'), findsNothing, reason: '前置：表还没来');

      // 标签表到了，widget 被重建。
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.pump();

      expect(find.text('标签推荐'), findsOneWidget);
      expect(find.text('女性'), findsOneWidget);
    });
  });

  group('点标签 → 立即进入 tag 查找模式', () {
    testWidgets('点候选：回调拿到不带 # 的标签名', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: picked.add,
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '女');
      await tester.pump();

      await tester.tap(find.text('女性'));
      await tester.pump();

      expect(picked, ['女性'], reason: '回调必须传裸标签名，不带 #');
    });

    testWidgets('点候选后输入框回填裸标签名（不再塞 # 回用户眼前）',
        (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: picked.add,
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '女');
      await tester.pump();
      await tester.tap(find.text('女性'));
      await tester.pump();

      final ctrl = tester.widget<TextField>(find.byType(TextField)).controller!;
      expect(ctrl.text, '女性',
          reason: '回填裸标签名：这次改动的方向就是不让用户看见 #');
    });

    testWidgets('点完推荐下拉收起（不糊住列表）', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '女');
      await tester.pump();
      expect(find.text('标签推荐'), findsOneWidget);

      await tester.tap(find.text('女性'));
      await tester.pump();

      expect(find.text('标签推荐'), findsNothing);
    });

    testWidgets('推荐项显示「热度」而不是「N 人」（票数≠人数）',
        (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '女');
      await tester.pump();

      expect(find.text('热度 7580'), findsOneWidget);
      expect(find.textContaining('7580 人'), findsNothing);
      expect(find.textContaining('7580个'), findsNothing);
    });
  });

  group('与搜索历史的互斥', () {
    testWidgets('有标签命中时弹推荐，不弹历史', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();

      // 直接写一条历史（不经过提交动作，见文件头说明）。
      StorageService.saveSearchHistory(['qianxi041015']);
      await StorageService.debugFlushPending();
      // 重建一次让 _loadHistory 重新读。
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '女');
      await tester.pump();

      expect(find.text('标签推荐'), findsOneWidget);
      expect(find.text('搜索历史'), findsNothing);
    });
  });

  tearDown(() async {
    // 搜索历史是**写盘**的静态状态。两件事都要做，缺一不可：
    //  1) 等挂起的写盘落定（`debugFlushPending`）—— 库里的写盘是串行链，
    //     不等就 reset 的话，链上的回调会在 reset 之后才跑，把已清空的
    //     内存态又写回去；
    //  2) `resetForTests()` 清内存态并解除「已加载」标记 —— 否则下一条用例
    //     会看到本条留下的历史。
    //
    // CI 那条「写盘测试必须重置静态状态」闸门只认
    // `StorageService.<写方法>(` 这种**直接调用**，本文件现在有了直接调用
    // （`saveSearchHistory`），闸门会查得到——但保留 `debugFlushPending`
    // 仍必要，因为闸门只查「有没有重置」，查不出「有没有等写盘链」。
    await StorageService.debugFlushPending();
    StorageService.resetForTests();
  });
}