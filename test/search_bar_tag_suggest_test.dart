// 搜索框标签推荐下拉 + 「点标签立即进入 tag 查找模式」的渲染判据。
//
// ## 这组测试拦的是什么
//
// 症状类只有一条：**点了推荐标签，列表没换**。它很难被肉眼抓住，因为推荐下拉
// 本身渲染正常、标签表也正常，只有「点下去之后走哪条数据路」错了。所以判据必须
// 落在**回调收到的标签名**与**回填进输入框的文本**上，而不是下拉看起来对不对。
//
// 第二个症状是**静默失败**：推荐一个都没匹配上时如果弹一个空框，用户会以为搜索
// 坏了。所以「无命中不弹框」也是判据。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/models/user.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';
import 'package:twitter_pic_flutter/widgets/search_bar.dart';

/// 一张贴近线上真实形状的标签表（实测 /api/tag-cloud?limit=500 → 178 个标签，
// 这里取热门那几个）。
final cloud = <TagCount>[
  const TagCount(tag: '女性', count: 7580),
  const TagCount(tag: '男女性交', count: 1554),
  const TagCount(tag: '二次元', count: 1456),
  const TagCount(tag: '自拍', count: 1196),
];

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('打 # 后弹标签推荐', () {
    testWidgets('打 # 立刻列出热门标签（还没打词也给起手推荐）', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '#');
      await tester.pumpAndSettle();

      expect(find.text('标签推荐'), findsOneWidget);
      // 热门里按热度取前 kTagSuggestLimit 条。
      expect(find.text('#女性'), findsOneWidget);
      expect(find.text('#男女性交'), findsOneWidget);
    });

    testWidgets('打 #女 只出匹配的标签', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '#女');
      await tester.pumpAndSettle();

      expect(find.text('#女性'), findsOneWidget);
      expect(find.text('#男女性交'), findsOneWidget);
      // 「二次元」不含「女」，不该出现在候选里。
      expect(find.text('#二次元'), findsNothing);
    });

    testWidgets('一个都没命中时不弹空框（不假装还能搜）', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '#zzz不存在');
      await tester.pumpAndSettle();

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
      await tester.enterText(find.byType(TextField), '#女');
      await tester.pumpAndSettle();

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
      await tester.enterText(find.byType(TextField), '#');
      await tester.pumpAndSettle();

      expect(find.text('标签推荐'), findsNothing);
    });

    testWidgets('标签表异步到货后，已经打好的 # 立刻开始推荐', (tester) async {
      // 真实时序：标签云是异步请求回来的，用户很可能在它回来之前就打了 #。
      // 若没有 didUpdateWidget 重算，这种时序下推荐面板**永远不出现**，
      // 症状是「打了 # 一点反应都没有」。
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: const <TagCount>[],
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '#女');
      await tester.pumpAndSettle();
      expect(find.text('标签推荐'), findsNothing, reason: '前置：表还没来');

      // 标签表到了，widget 被重建。
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('标签推荐'), findsOneWidget);
      expect(find.text('#女性'), findsOneWidget);
    });

    testWidgets('不打 # 时不弹推荐（普通账号搜索不受影响）', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '女');
      await tester.pumpAndSettle();

      expect(find.text('标签推荐'), findsNothing);
      expect(find.text('#女性'), findsNothing);
    });
  });

  group('点标签 → 立即进入 tag 查找模式', () {
    testWidgets('点推荐标签：回调拿到不带 # 的标签名', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: picked.add,
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '#女');
      await tester.pumpAndSettle();

      await tester.tap(find.text('#女性'));
      await tester.pumpAndSettle();

      expect(picked, ['女性'], reason: '回调必须传裸标签名，不带 #');
    });

    testWidgets('点推荐标签后输入框回填 #标签名', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: picked.add,
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '#女');
      await tester.pumpAndSettle();
      await tester.tap(find.text('#女性'));
      await tester.pumpAndSettle();

      final ctrl = tester.widget<TextField>(find.byType(TextField)).controller!;
      expect(ctrl.text, '#女性',
          reason: '回填要让用户看见「我在按标签搜」，而不是输入框突然被清空');
    });

    testWidgets('点完推荐下拉收起（不糊住列表）', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '#女');
      await tester.pumpAndSettle();
      expect(find.text('标签推荐'), findsOneWidget);

      await tester.tap(find.text('#女性'));
      await tester.pumpAndSettle();

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
      await tester.enterText(find.byType(TextField), '#');
      await tester.pumpAndSettle();

      expect(find.text('热度 7580'), findsOneWidget);
      expect(find.textContaining('7580 人'), findsNothing);
      expect(find.textContaining('7580个'), findsNothing);
    });
  });

  group('与搜索历史的互斥', () {
    testWidgets('打了 # 就优先弹推荐，不弹历史', (tester) async {
      await tester.pumpWidget(wrap(SearchBarWidget(
        onChanged: (_) {},
        tagCloud: cloud,
        onPickTag: (_) {},
      )));
      // 先制造一条历史并提交，让它落进 StorageService。
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'qianxi041015');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '#女');
      await tester.pumpAndSettle();

      expect(find.text('标签推荐'), findsOneWidget);
      expect(find.text('搜索历史'), findsNothing);
    });
  });

  tearDown(() async {
    // 搜索历史是写盘的静态状态（StorageService.saveSearchHistory）。不清就会
    // 让下一条用例看到上一条留下的历史 —— 这正是 CI 那条
    // 「写盘测试必须重置静态状态」闸门要拦的串味。
    await StorageService.debugFlushPending();
    StorageService.resetForTests();
  });
}