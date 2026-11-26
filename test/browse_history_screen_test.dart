// browse_history_screen_test.dart
// 最近浏览历史页面组件测试：空状态、列表展示、搜索过滤、单条删除与屏蔽联动。
//
// ⚠️ 遵循仓库静态状态隔离铁律：
//   - setUp / tearDown 显式调用 StorageService.resetForTests() 与 TwitterApi.resetForTests()；
//   - 不在 setUp 中调用 ensureInitialized()，保持 _file == null，避免假异步时钟下触发真实磁盘 IO。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';
import 'package:twitter_pic_flutter/screens/browse_history_screen.dart';
import 'package:twitter_pic_flutter/services/proxy_manager.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';

void main() {
  late ProxyManager proxy;

  setUp(() {
    StorageService.resetForTests();
    TwitterApi.resetForTests();
    proxy = ProxyManager();
  });

  tearDown(() {
    StorageService.resetForTests();
    TwitterApi.resetForTests();
    proxy.dispose();
  });

  testWidgets('无历史记录时显示空态提示', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: BrowseHistoryScreen(proxy: proxy)),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('暂无浏览历史'), findsOneWidget);
  });

  testWidgets('展示最近浏览记录，支持搜索过滤与单条删除，且隐藏已屏蔽账号', (tester) async {
    StorageService.addBrowseHistory(
      'alice',
      nick: 'Alice Wonderland',
      visitedAtMs: 1000,
    );
    StorageService.addBrowseHistory(
      'bob',
      nick: 'Bob Builder',
      visitedAtMs: 2000,
    );
    StorageService.addBrowseHistory(
      'blocked_acc',
      nick: 'Blocked User',
      visitedAtMs: 3000,
    );
    StorageService.addBlockedUser('blocked_acc');

    await tester.pumpWidget(
      MaterialApp(home: BrowseHistoryScreen(proxy: proxy)),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 已屏蔽账号不显示，其余两条正常显示
    expect(find.text('Alice Wonderland'), findsOneWidget);
    expect(find.text('Bob Builder'), findsOneWidget);
    expect(find.text('Blocked User'), findsNothing);

    // 搜索过滤
    await tester.enterText(find.byType(TextField), 'alice');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Alice Wonderland'), findsOneWidget);
    expect(find.text('Bob Builder'), findsNothing);

    // 清空搜索框后恢复显示，并测试单条移除
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Bob Builder'), findsOneWidget);

    await tester.tap(find.byTooltip('移除此条记录').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Bob Builder'), findsNothing);
    expect(find.text('Alice Wonderland'), findsOneWidget);
  });
}
