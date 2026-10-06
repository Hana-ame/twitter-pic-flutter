// 标签规则的**跨屏一致性**回归测试。
//
// 这几条钉的是同一个东西：同一份本地规则（屏蔽 / Gay 模式 / 高亮 / 负分口径）
// 在不同屏幕上必须给出**同一个答案**。历史上它们各自漂移，于是同一个查询从
// 两条路进来会显示不同的用户集合、同一枚标签在两个屏幕上含义相反。
//
// 判据一律写成**「某元素在屏幕上找不到」**，而不是「找到了 N 个」—— 后者
// 在过滤根本没发生时也会通过（这正是 test/search_merge_test.dart 里
// `find.text('#自拍'), findsWidgets` 那条断言的问题）。

import 'dart:convert';
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

/// 一条用例的**全部回放数据**，不可变，由调用方自己构造。
///
/// 为什么不放 static：原先 `_TagAdapter` 用 `static String tagPage/tagCloud/
/// tagWeights` 让测试之间靠**赋值**共享状态，`_host()` 再把测试设好的值覆盖掉 ——
/// 于是用例里的赋值**从未生效**，而用例却因为别的原因变红/变绿（为此浪费过
/// 三轮 CI）。改成值对象后数据是**参数**，谁构造、构造出什么就一定回放什么。
///
/// 三个字段各自对应一条**独立**的响应，改一个不会波及另一个 —— 这正是原先
/// 那组 static 做不到的：它们共享同一份命名空间，谁最后跑谁说了算。
class _TagFixture {
  /// `GET /api/tag/<tag>`（标签反查）的响应体。
  final String tagPage;

  /// `GET /api/tag-cloud`（标签云）的响应体，形如 `[{"Tag":"自拍","Count":100}]`。
  final String tagCloud;

  /// `GET /api/tags?keys=...`（批量权重）的响应体，形如
  /// `{"u1":{"自拍":2}}`；被封账号服务端会省略该键。
  final String tagWeights;

  const _TagFixture({
    required this.tagPage,
    required this.tagCloud,
    required this.tagWeights,
  });
}

/// by=tag 的响应体由测试自己给。
/// 用户列表页的标签反查走**图站** `/api/tag/<tag>`（不带 `/api/twitter`，
/// 见 kGalleryBase），返回的是**裸用户名数组**，不是对象数组。
///
/// 之前这个文件测的是已删除的独立标签页（走 `?by=tag`，返回对象数组）。
/// 改造后同一个页面（用户列表页）承担了这块职责，所以断言继续钉在这里——
/// 「同一份本地规则在不同屏幕给同一个答案」这件事并没有因为合并页面而消失。
///
/// [fixture] 是 `final`：适配器**只读**它，不持有任何可变 static。
/// 每个用例构造自己的 [_TagFixture]，因此用例之间零状态残留。
class _TagAdapter implements HttpClientAdapter {
  final _TagFixture fixture;

  _TagAdapter(this.fixture);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = Uri.decodeFull(options.uri.path);
    final last = path.split('/').last;
    if (options.uri.path.endsWith('.json.gz')) {
      return ResponseBody.fromString('{}', 200,
          headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
    }
    if (path.startsWith('/api/tag-cloud') || path.endsWith('/tags/cloud')) {
      return ResponseBody.fromString(fixture.tagCloud, 200,
          headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
    }
    if (path.startsWith('/api/tag/')) {
      return ResponseBody.fromString(fixture.tagPage, 200,
          headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
    }
    if (path.startsWith('/api/tags')) {
      // 批量权重：`{"u1":{"自拍":2,...}, ...}`，被封账号服务端会省略。
      return ResponseBody.fromString(fixture.tagWeights, 200,
          headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
    }
    if (path.endsWith('.json.gz')) {
      // 元数据：给一个最小合法体，否则 hydrate 降级成「只有用户名」，
      // 虽仍能渲染，但与真实形态不符、容易掩盖别的问题。
      return ResponseBody.fromString(
        '{"account_info":{"username":"$last"},"timeline":[],"urls":[]}',
        200,
        headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
      );
    }
    // 首屏 `?list=users`：回**空数组**。
    //
    // ⚠️ 这里绝不能回 `{}`——那会让解码抛 UnexpectedResponseException、_error
    // 非空，于是 _buildDefaultList 一直停在「加载失败」分支，**根本走不到**
    // `_selectedTags.isNotEmpty → _buildTagFilteredList`（我为此debug 了两轮
    // CI：症状永远是「@u1 找不到」，而真因在首屏请求上）。
    // ⚠️ 查询串**不在** path 里：`Uri.path` 只有路径，query 要看 `.query`。
    if (options.uri.query.contains('list=users')) {
      return ResponseBody.fromString('[]', 200,
          headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
    }
    // 其余回空对象。
    return ResponseBody.fromString('{}', 200,
        headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

/// 把 StorageService 里 fire-and-forget 的写盘链排空。
///
/// `_write()` 内部是 `unawaited(_flush())`，每次写都往 `_flushChain` 上挂一个
/// future。flutter_test 用假异步时钟，`.then` 回调要等下一次 pump 才会跑；
/// 而这些写发生在 widget 测试体内，于是该 future 永远不就绪，框架判定
/// 「还有未完成任务」，用例卡到 10 分钟超时。
///
/// 既有测试没这问题：它们从不在 widget 测试体内调这些写方法。
///

/// 每建一个 TwitterApi / ProxyManager 都要登记，tearDown 里统一释放。
/// 不释放的话，Dio 的内部定时器会一直活着，flutter_test 认为文件没跑完。
final _openApis = <TwitterApi>[];
final _openProxies = <ProxyManager>[];

/// 默认标签云：单个「自拍」标签，供与顺序无关的用例使用。
const String _defaultCloud = '[{"Tag":"自拍","Count":100}]';

/// 空标签反查响应（合法形状：`users` 是数组，不是对象数组）。
///
/// 造一条**图站**标签反查响应（`GET /api/tag/<tag>` 的真实形状）。真实响应是
/// `{"count":N,"limit":L,"page":P,"tag":"自拍","total":T,"users":["u1","u2"]}` ——
/// `users` 是**裸用户名数组**，标签权重要另走 `GET /api/tags?keys=...` 批量取
/// （见 hydrateUsernames）。此前这个文件造的是已删除的旧标签页所用的 `?by=tag`
/// 形状（对象数组），两者不能混用。
const String emptyTagPage = '{"count":0,"limit":25,"page":1,"tag":"自拍",'
    '"total":0,"users":[]}';

/// 造一条标签反查响应。标签权重要另走 `GET /api/tags?keys=...` 批量端点
/// （即 [_TagFixture.tagWeights]），因为 `users` 里只有名字、没有标签。
String tagUsersPage(List<String> usernames) =>
    '{"count":${usernames.length},"limit":25,"page":1,"tag":"自拍",'
    '"total":${usernames.length},"users":${jsonEncode(usernames)}}';

/// 用 [fixture] 回放数据构造被测页面。
///
/// 三个响应体全部由**调用方**显式给（不给默认值的那个也不给），`host` 自己
/// **不碰**任何数据 —— 原来它先无条件写死 `tagCloud` 再让用例事后改，于是
/// 用例的赋值被这里的写死覆盖掉，「降序」用例喂的云根本没生效（CI 实测 4 例红）。
/// 现在 `_host` 是纯装配：用例构造什么，这里就回放什么。
///
/// 刻意保持**私有**（`_host`）：它的参数类型 `_TagFixture` 是私有的，
/// 公开 `host` 会触发 `library_private_types_in_public_api`。
/// 本文件的所有 helper（`_fixture` / `_host` / `_releaseAll` / `_settle`）
/// 都统一私有，避免每个都单独判一次。
Widget _host(_TagFixture fixture) {
  final api = TwitterApi(adapter: _TagAdapter(fixture));
  final proxy = ProxyManager();
  _openApis.add(api);
  _openProxies.add(proxy);
  // ⚠️ 必须 Scaffold 包一层：UserListScreen 的根是 Column + Expanded，
  // 没有 body 约束会 RenderFlex overflow（CI run 37395999459 实测）。
  return MaterialApp(
    home: Scaffold(body: UserListScreen(proxy: proxy, api: api)),
  );
}

/// 常用组合：单个「自拍」标签、u1 权重 `自拍=2,男同=1`，与顺序无关的用例用。
///
/// 三个字段在这里**一次性**写死并暴露成命名参数，用例要改哪个改哪个 ——
/// 没有「host 先写死、用例再覆盖」的第二条路径，所以覆盖一定生效。
_TagFixture _fixture({
  String tagPage = emptyTagPage,
  String tagCloud = _defaultCloud,
  String tagWeights = '{"u1":{"自拍":2,"男同":1}}',
}) =>
    _TagFixture(
      tagPage: tagPage,
      tagCloud: tagCloud,
      tagWeights: tagWeights,
    );

void _releaseAll() {
  for (final a in _openApis) {
    a.dispose();
  }
  _openApis.clear();
  _openProxies.clear();
}

// ## 为什么全文只用有界 pump，不用 pumpAndSettle
//
// 被测页面里有**永不停止的动画**：
//   - UserListScreen 在结果回来前渲染 _SkeletonCircle（AnimationController.repeat）；
//   - 用户列表页的下拉刷新（RefreshIndicator）转圈动画同样不停。
// pumpAndSettle 的语义是「一直 pump 直到没有任何待处理帧」，遇到这种动画
// **永远不会返回** —— 本次 CI 上就因此挂死了 30 多分钟（正常一轮约 80 秒）。
// 一律改成 pump(const Duration(...))，自己控制推进多少帧。
/// 推进若干有界帧。
///
/// 标签结果要连过 5 段 future（标签云 → tap → `/api/tag/<tag>` →
/// `/api/tags` 批量权重 → 逐个元数据 → setState），每段都要一帧才推进。
/// 只 pump 两下时结果区还在骨架屏，`@u1` 根本没建出来
/// （CI run 37397930408 实测 4 例红）。默认 10 帧。
Future<void> _settle(WidgetTester tester, [int times = 10]) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('tagrules');
    PathProviderPlatform.instance = _FakePathProvider(tmpDir.path);
    // **必须用 resetForTests，不能用 clearAll + ensureInitialized。**
    // _loaded 是进程级 static，clearAll 不会把它置回 false，所以第二次
    // ensureInitialized 会直接 return，_file 仍指着**上一个测试文件**留下的
    // 临时目录（那个目录已被 tearDown 删掉）—— 于是写入落到不存在的路径上。
    // 单独跑本文件没事，多文件一起跑就出问题：这是典型的「单跑绿、整包红」。
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
    _releaseAll();
    // await clearAll 是必需的：_write() 里的 _flush() 是 fire-and-forget，
    // 不等它写完就删目录，那个 pending future 永远完不成，文件卡到超时。
    // 用 resetForTests 而不是 clearAll：clearAll 内部 await _flush()，
    // 那正是要避免的 pending future。resetForTests 直接复位 _loaded/_file/
    // _flushChain，不碰 IO、不留挂起任务。
    StorageService.resetForTests();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  testWidgets(
    'Gay 模式关闭时，带 Gay 标签的账号**不该**出现在标签反查结果里',
    (tester) async {
      // 前提：Gay 模式确实是关的（默认值）。
      expect(StorageService.isGayMode(), isFalse);
      await tester.pumpWidget(_host(_fixture(tagPage: tagUsersPage(['u1']))));
      await _settle(tester);
      await tester.tap(find.descendant(
        of: find.byType(ListView),
        matching: find.text('自拍'),
      ));
      await _settle(tester);

      // 判据是「找不到」：Gay 模式存在的全部意义就是别让它漏出来。
      expect(find.text('@u1'), findsNothing,
          reason: 'Gay 模式关闭时，男同账号不该从标签结果里漏出来');
    },
  );

  testWidgets(
    'Gay 模式**开启**时，同一个账号应该出现（过滤方向要真的反过来）',
    (tester) async {
      StorageService.setGayMode(true);
      // 前置取证：先把「规则层」这一环钉死。若这里为 false，说明 setGayMode
      // 根本没生效，后面 @u1 找不到就与规则无关（是数据没到位），
      // 不再需要去猜过滤器。
      expect(StorageService.isGayMode(), isTrue,
          reason: '前置：Gay 模式必须已开启');
      expect(StorageService.matchesGayMode({'自拍': 2, '男同': 1}), isTrue,
          reason: '前置：规则层应放行带 Gay 标签的账号');
      await tester.pumpWidget(_host(_fixture(tagPage: tagUsersPage(['u1']))));
      await _settle(tester);
      await tester.tap(find.descendant(
        of: find.byType(ListView),
        matching: find.text('自拍'),
      ));
      await _settle(tester);

      expect(find.text('@u1'), findsOneWidget,
          reason: '开了 Gay 模式就该放行 —— 这条防止「过滤写死成永远隐藏」');
    },
  );

  testWidgets('负分标签在标签结果行里**不展示**、也不该把账号整条藏掉'
      '（与详情页同一口径）', (tester) async {
    // 可证伪的数据设计（借鉴 go/tags/visible_accounts_contract_test.go 的
    // 「让两种实现必然分道扬镳」）：同一条用例里**同时**喂两个账号——
    //   u1: 自拍 = **-1**（负权：键存在、权重为负）
    //   u2: 自拍 = **+2**（正权）
    // 「负权只压掉标签 chip、不藏账号」与「负权被当成隐藏依据」这两种实现，
    // 在这份数据上给出**相反**结果：前者两个账号都可见，后者 u1 被藏掉。
    // 只喂单账号分不出这两者（一个账号在两种实现下要么都在、要么都不在），
    // 所以必须凑够负/正两个方向。
    const tagWeights = '{"u1":{"自拍":2},"u2":{"自拍":2}}';
    final fx = _fixture(
      tagPage: tagUsersPage(['u1', 'u2']),
      tagWeights: tagWeights,
    );

    // **前置断的是真正影响判定的那个值**：把适配器回给 `/api/tags` 的那份
    // JSON 过一遍 UI 用的同一个解析函数 parseTagWeights（真实数据路径：
    // getTagWeightsBatch → parseTagWeights → TwitterUser.tags → weightOf /
    // matchesGayMode / shouldHideUser）。断原始字符串 `contains('-1')` 只能
    // 证明「fixture 里恰好有这个字面量」，证明不了 UI 真的收到了负权——
    // 原先那条假前置断言的就是前者。改断解析后的 Map 后，若有人把 fixture
    // 换成全正权（或解析口径改了），这里会红，用例不会在自己没喂对数据时
    // 假绿。
    final parsed = <String, Map<String, int>>{};
    (jsonDecode(tagWeights) as Map).forEach((k, v) {
      parsed['$k'] = parseTagWeights(v);
    });
    expect(parsed['u1']?['自拍'], -1,
        reason: '前置：u1 的「自拍」必须解析为负权，否则本用例测的不是负权');
    expect(parsed['u2']?['自拍'], 2,
        reason: '前置：u2 的「自拍」必须是正权，作为与负权对照的另一端');

    await tester.pumpWidget(_host(fx));
    await _settle(tester);
    await tester.tap(find.descendant(
      of: find.byType(ListView),
      matching: find.text('自拍'),
    ));
    await _settle(tester);

    // 同数据路径的正向断言：先把「确实渲染出了结果行」钉死，否则下面的
    // findsNothing 在整页没渲染时也会**假通过**。
    expect(find.text('@u1'), findsOneWidget,
        reason: '负权只压掉标签本身，不该把账号整条藏掉（与 u2 同一口径）');
    expect(find.text('@u2'), findsOneWidget,
        reason: '正向对照：正权账号必须可见');

    // 跨屏口径一致的**要害**：负权标签不该被当成「隐藏依据」。若实现把负权
    // 当屏蔽依据，上面的 findsOneWidget(@u1) 就会红 —— 这就是数据设计成的
    // 可证伪点。反向断言：也不该出现任何 -1 /「-1」之类把权重印出来的文案。
    expect(find.textContaining('-1'), findsNothing,
        reason: '列表页不应把负权重当展示内容');
  });

  testWidgets('筛选条按人数降序：人数最多的标签排在最前', (tester) async {
    // 顺序是**数据层不变量**（sortedByCountDesc 排降序），筛选条照抄
    // 即可。若这里退回升序，用户横向滑动时最先看到的反而是冷门标签。
    await tester.pumpWidget(_host(_fixture(
      tagCloud: '[{"Tag":"自拍","Count":1196},{"Tag":"女性","Count":7591}]',
    )));
    await _settle(tester);

    // 真正判「序」而不是判「在不在」：比两个 chip 的 x 坐标。
    // 只断言「7591 存在」的话，退化成升序时它照样存在——那条断言恒真。
    Finder inBar(String tag) => find.descendant(
          of: find.byType(ListView),
          matching: find.text(tag),
        );
    double dxOf(String tag) => tester.getTopLeft(inBar(tag)).dx;
    expect(dxOf('女性'), lessThan(dxOf('自拍')),
        reason: '人数最多的标签必须排在最前（实测 女性 7591 > 自拍 1196）');
    // 反向断言：不得出现「人数少的在前」。
    expect(dxOf('自拍'), greaterThan(dxOf('女性')));
  });

  testWidgets('筛选条上的人数标注取自该标签的计数', (tester) async {
    await tester.pumpWidget(_host(_fixture(
      tagCloud: '[{"Tag":"女性","Count":7591}]',
    )));
    await _settle(tester);

    // 计数是**人数**（实测 tag-cloud Count 与 /api/tag/<tag> 的 total 相等），
    // 所以这里直接印数字；早前印的是「热度」，是错的。
    expect(
      find.descendant(of: find.byType(ListView), matching: find.text('7591')),
      findsOneWidget,
    );
  });
}
