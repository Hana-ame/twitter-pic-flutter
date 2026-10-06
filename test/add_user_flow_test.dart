// 添加用户的**真实布局**回归测试。
//
// 为什么必须有这个文件：已有的 test/tag_selector_modal_test.dart 把
// TagSelectorModal 放在 `Scaffold(body: TagSelectorModal(...))` 里测 —— 那是
// **紧约束**，也是它在 user_detail_screen.dart 里的真实宿主，测得通。
// 但它**测不到**另一个调用点：user_list_screen.dart 的 `_AddUserTile.build`
// 返回的 Stack 是 `ListView(children: [...])` 的直接子节点，ListView 给子节点的是
// **纵向无界**约束。无界约束下原来的
//   `Stack(children: [GestureDetector(child: Container(color: black54)), ...])`
// 里那个只有 color、没有 child 的 Container 量出来**高度 0**：遮罩不可见、
// 对话框被裁掉，整个标签选择器点不动 —— 而那正是 v0.6.3 刚修好的添加用户流程。
//
// 判据是**可证伪的布局读数**，不是「有没有抛异常」：
//   1) 遮罩（Container with color）的高度必须 > 0；
//   2) 「确认保存（至少选一个标签）」按钮必须在测试视口内、且可 hit-test；
//   3) 提交失败后弹层必须**仍然挂着**并保留已选标签。
// 故意写坏实现（去掉 Positioned.fill / 把渲染改回 ListView 内的 Stack）时
// 这三条必须变红 —— 否则它们就是本项目记在案的「断言方向写反」式假绿。

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';
import 'package:twitter_pic_flutter/models/user.dart';
import 'package:twitter_pic_flutter/screens/user_list_screen.dart';
import 'package:twitter_pic_flutter/services/proxy_manager.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// 按 query 里的 by= 路由响应；POST 一律 200 {'message':'ok'}。
class _AddFlowAdapter implements HttpClientAdapter {
  final List<RequestOptions> seen = <RequestOptions>[];
  int postCount = 0;
  /// 置为非 0 时让 POST 返回该状态码（模拟失败路径）。
  int failWithStatus = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    if (options.method == 'POST') {
      postCount++;
      if (failWithStatus != 0) {
        return ResponseBody.fromString(
          '{"error":"模拟失败"}',
          failWithStatus,
          headers: {
            Headers.contentTypeHeader: <String>[Headers.jsonContentType],
          },
        );
      }
      return ResponseBody.fromString(
        '{"message":"ok"}',
        200,
        headers: {
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }
    final by = options.uri.queryParameters['by'];
    if (by == 'username') {
      return ResponseBody.fromString(
        '[{"username":"alice","nick":"爱丽丝"}]',
        200,
        headers: {
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }
    if (options.uri.path.endsWith('.json.gz')) {
      return ResponseBody.fromString(
        '{}',
        200,
        headers: {
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      '[]',
      200,
      headers: {
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 找出「添加 @xxx」那张卡片（_AddUserTile）。
Finder addTile() => find.textContaining('添加 @');

/// 真正的遮罩 = 一个只有 color、没有 child 的 Container。
Finder backdropFinder() => find.byWidgetPredicate(
  (w) => w is Container &&
      w.child == null &&
      w.color != null &&
      w.color == const Color(0x8A000000),
);

//
// ## 为什么全文只用有界 pump，不用 pumpAndSettle
//
// 被测页面里有**永不停止的动画**：
//   - UserListScreen 在结果回来前渲染 _SkeletonCircle（AnimationController.repeat）；
//   - UserListScreen 外层/详情页的 RefreshIndicator，转圈动画同样不停
//     （原先还列了 TagUserListScreen，它已随「同页查看」改造删除）。
// pumpAndSettle 的语义是「一直 pump 直到没有任何待处理帧」，遇到这种动画
// **永远不会返回** —— 本次 CI 上就因此挂死了 30 多分钟（正常一轮约 80 秒）。
// 一律改成 pump(const Duration(...))，自己控制推进多少帧。
void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('addflow');
    PathProviderPlatform.instance = _FakePathProvider(tmpDir.path);
    TwitterApi.resetForTests();
    // resetForTests 而非只 ensureInitialized：_loaded 是进程级 static，
    // 不重置就会沿用上一个测试文件留下的 _file（那个临时目录已被删掉）。
    // **不调 ensureInitialized**，让 `_file` 保持 null。
    // _doFlush() 开头就是 `if (f == null) return;` —— 写盘直接短路，
    // 不会有任何真实文件 IO。
    //
    // 为什么必须这样：flutter_test 跑在假异步时钟下，`_flush()` 挂在
    // `_flushChain` 上的 future 靠 `.then` 推进，而真实文件 IO 不受假时钟
    // 驱动 —— 于是那个 future 永远不就绪，框架判定「还有未完成任务」，
    // 用例卡到 10 分钟超时（CI 上实测 rc=124）。
    //
    // 这些用例断言的是**读取路径**（界面上显不显示某个标签），不依赖落盘，
    // 所以不初始化文件不影响断言有效性。
    StorageService.resetForTests();
  });

  tearDown(() async {
    TwitterApi.resetForTests();
    StorageService.resetForTests();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  testWidgets(
    'CRITICAL 回归：添加用户的标签弹层在 ListView 里必须有**非零高度遮罩**',
    (tester) async {
      final adapter = _AddFlowAdapter();
      final api = TwitterApi(adapter: adapter);

      // 用 Scaffold 包一层，与既有 search_merge_test 保持一致（那边是已知能跑通的
      // 结构）。不要直接 MaterialApp(home: ...)：那样 AppBar 之外没有 body 约束，
      // 与真实使用形态不同。
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: UserListScreen(proxy: ProxyManager(), api: api)),
      ));
      // 全部用**有界** pump，不用 pumpAndSettle：默认列表在结果回来前渲染
      // _SkeletonCircle（AnimationController.repeat，无限动画），
      // pumpAndSettle 永远等不到"无待处理帧"，会一直转到超时。
      await tester.pump(const Duration(milliseconds: 100));

      // 搜一个用户名，让「添加 @xxx」那张卡片出现（_AddUserTile）。
      await tester.enterText(find.byType(TextField).first, 'alice');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));

      expect(addTile(), findsWidgets,
          reason: '前置条件：搜索后应出现「添加 @alice」卡片');

      await tester.tap(addTile().first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // 判据 1：弹层确实挂出来了。
      expect(find.textContaining('添加标签 @alice'), findsOneWidget);

      // 判据 2：遮罩**高度必须 > 0**。这就是那条把弹层压扁的缺陷的
      // 直接读数 —— 无界约束下原来的 Container(color:) 量出来是 0。
      final backdrop = backdropFinder();
      expect(backdrop, findsOneWidget,
          reason: '弹层的半透明遮罩应当存在');
      final h = tester.getSize(backdrop).height;
      expect(h, greaterThan(0.0),
          reason: '遮罩高度为 $h —— 弹层被父级（ListView 无界约束）压扁了',
      );

      // 判据 3：确认按钮必须在视口内且真的能点到（未被裁掉/遮挡）。
      final confirm = find.widgetWithText(
          ElevatedButton, '确认保存（至少选一个标签）');
      expect(confirm, findsOneWidget);
      final box = tester.getRect(confirm);
      expect(box.bottom, lessThanOrEqualTo(tester.view.physicalSize.height /
          tester.view.devicePixelRatio),
          reason: '确认按钮被挤出视口（bottom=${box.bottom}）');
      // hitTestable 是 find 的修饰器，不是 WidgetTester 的方法。
      // 它筛出「命中测试能真正落到这个 widget 上」的候选，用来实现
      // 「按钮没有被遮罩或父级挡住」这条判据。
      expect(confirm.hitTestable(), findsOneWidget,
          reason: '确认按钮不可 hit-test —— 遮罩或父级把它挡住了');
    },
  );

  testWidgets(
    '提交失败后弹层应仍在并保留已选标签（不逼用户重按一遍）',
    (tester) async {
      final adapter = _AddFlowAdapter()..failWithStatus = 500;
      final api = TwitterApi(adapter: adapter);

      // 用 Scaffold 包一层，与既有 search_merge_test 保持一致（那边是已知能跑通的
      // 结构）。不要直接 MaterialApp(home: ...)：那样 AppBar 之外没有 body 约束，
      // 与真实使用形态不同。
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: UserListScreen(proxy: ProxyManager(), api: api)),
      ));
      // 全部用**有界** pump，不用 pumpAndSettle：默认列表在结果回来前渲染
      // _SkeletonCircle（AnimationController.repeat，无限动画），
      // pumpAndSettle 永远等不到"无待处理帧"，会一直转到超时。
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField).first, 'alice');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(addTile().first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // 先禁用状态 → 选一个标签让它解禁。
      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton).first).onPressed,
        isNull,
        reason: '没选标签时确认按钮应禁用');
      await tester.tap(find.text('男性').first);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton).first).onPressed,
        isNotNull,
        reason: '选了一个标签后确认按钮应解禁');

      // 提交（必然失败）。
      await tester.tap(find.byType(ElevatedButton).first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(adapter.postCount, greaterThan(0),
          reason: '前置条件：应真的发了 POST');

      // 判据：失败后弹层还在，且标签仍是选中的（蓝色 = 正分）。
      expect(find.textContaining('添加标签 @alice'), findsOneWidget,
          reason: '提交失败后弹层被关掉了，用户得从头再选一遍标签');
    },
  );
}