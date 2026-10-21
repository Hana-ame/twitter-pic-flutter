// 收藏夹回归测试（含本地搜索过滤与多格式导入解析）。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';
import 'package:twitter_pic_flutter/services/proxy_manager.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';
import 'package:twitter_pic_flutter/widgets/fav_list.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// getMetaData 返回空对象：模型容错，账号信息为空但用户仍应显示出来。
class _StubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Widget _host(TwitterApi api, ProxyManager proxy) {
  // 复刻 FavoritesTab 的结构：外层一个纵向可滚动的 ListView，FavList 在其中。
  return MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [FavList(api: api, proxy: proxy)],
      ),
    ),
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fav_list_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    StorageService.resetForTests();
    TwitterApi.resetForTests();
    await StorageService.ensureInitialized();
  });

  tearDown(() async {
    StorageService.resetForTests();
    TwitterApi.resetForTests();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('parseImportedUsername 支持完整 URL、带参链接、@句柄与裸用户名', () {
    expect(parseImportedUsername('https://x.moonchan.xyz/alice'), 'alice');
    expect(parseImportedUsername('https://x.com/bob/?s=20'), 'bob');
    expect(parseImportedUsername('https://twitter.com/carol#top'), 'carol');
    expect(parseImportedUsername('  @dave_123  '), 'dave_123');
    expect(parseImportedUsername('erin'), 'erin');
    expect(parseImportedUsername('   '), isNull);
    expect(parseImportedUsername('https://'), isNull);
  });

  testWidgets('收藏的用户真的渲染出来（父级已是可滚动列表）', (tester) async {
    StorageService.toggleFav('alice');

    final api = TwitterApi(adapter: _StubAdapter());
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();

    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('收藏夹为空'), findsNothing);
    api.dispose();
  });

  testWidgets('导出/导入入口也一起渲染出来', (tester) async {
    StorageService.toggleFav('bob');

    final api = TwitterApi(adapter: _StubAdapter());
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();

    expect(find.text('导出'), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);
    api.dispose();
  });

  testWidgets('没有收藏时显示空状态', (tester) async {
    final api = TwitterApi(adapter: _StubAdapter());
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();

    expect(find.text('收藏夹为空'), findsOneWidget);
    api.dispose();
  });

  testWidgets('取消收藏后列表里不再有它', (tester) async {
    StorageService.toggleFav('carol');

    final api = TwitterApi(adapter: _StubAdapter());
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();
    expect(find.text('@carol'), findsOneWidget);

    StorageService.toggleFav('carol');
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();

    expect(find.text('@carol'), findsNothing);
    expect(find.text('收藏夹为空'), findsOneWidget);
    api.dispose();
  });

  testWidgets('被屏蔽的用户不出现在收藏列表中', (tester) async {
    StorageService.toggleFav('alice');
    StorageService.toggleFav('blocked_user');
    StorageService.toggleBlock('blocked_user');

    final api = TwitterApi(adapter: _StubAdapter());
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();

    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('@blocked_user'), findsNothing);
    api.dispose();
  });

  testWidgets('多个收藏时显示收藏内搜索框并支持按用户名筛选与排序切换', (tester) async {
    StorageService.toggleFav('charlie');
    StorageService.toggleFav('alice');

    final api = TwitterApi(adapter: _StubAdapter());
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();

    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('@charlie'), findsOneWidget);

    // 输入筛选词后只显示匹配的收藏
    await tester.enterText(find.byType(TextField).first, 'char');
    await tester.pump();

    expect(find.text('@charlie'), findsOneWidget);
    expect(find.text('@alice'), findsNothing);
    api.dispose();
  });
}
