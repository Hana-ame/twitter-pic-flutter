# Sub Agent 并行检查：分解方案与执行约束

> 用于把全项目质量检查拆成互不重叠的段，派 sub agent 并行只读审查。
> 本方案由 2026-09-10 一轮 8 段检查 + 一轮分解方案审查修正而来，
> 记录了那次实证的遗漏、粒度失衡与 CI 空转原因。

## 何时使用

- 全项目/大面积质量巡检（不是单点 bug 定位）
- 新增一批文件后需要整体过一遍
- 大版本升级（Flutter / Go / 目标 SDK）后的兼容性巡检

不适用于：单个文件的重构、纯 UI 调优、CI 配置改动（直接改并推 tag）。

## 分解原则（违反任一条都会重演上次的空转）

1. **文件互斥**：每个源码文件恰好出现在一个段里，不允许跨段重复检查。
2. **测试与源码同段强制配对**：改 `lib/foo.dart` 的段必须同时审 `test/foo_test.dart`。
   上次 `user.dart` 加容错，是靠父 agent 手工先读 `user_model_test.dart` 才没破坏断言——方案里本该有 agent 负责。
3. **强绑定组件同段**：调用方与被调用方的契约必须在一个 agent 手里。
   上次 `proxy_avatar`（G）报告的"头像降级后不回落 ECH"，修法在 `proxy_manager`（E），跨段导致结论失效。
4. **单段 ≤ 800 行**：超过就拆。`twitter_video`（797 行、2 个 State 类）
   与 `twitter_image` 同段时，是本轮唯一在 CI 炸出作用域错误的段——上下文被稀释的信号。
5. **跨语言/跨端一致性同段**：Go 单入口（`ech-flutter-shared`）
   的任何 handler 改动必须双端同步，只有同段 agent 能看出单边修改。

## 9 段清单

行数随代码演进变化，以当前值为准；分段边界不看行数看内聚性。

| 段 | 范围 | 文件 | 行数 | 检查重点 |
|----|------|------|------|----------|
| **1** | 构建/CI/Go 入口 | `.github/workflows/{build,ech-proxy-apk,native_ech_poc}.yml`、`pubspec.yaml`、`ech-proxy/go.mod`、`ech-proxy/main.go` | 682+ | 版本号生成（分支触发时 `ref_name` 非合法版本）、权限注入后置校验、Go 版本与 `go.mod` 对齐、三个 Go 入口行为一致性、release 竞态 |
| **2** | 代理层 + 头像 | `lib/services/proxy_manager.dart`、`lib/utils/ech_url.dart`、`lib/utils/doh_resolver.dart`、`lib/widgets/proxy_avatar.dart`、`ech-proxy/cmd/ech-flutter-shared/main.go`、`test/ech_url_test.dart`、`test/proxy_manager_test.dart` | 1350 | FFI 符号 12 个是否齐全、`normalizePath` 路径规范化、`getLogs()` 空安全、`proxyMu` 持锁跨同步调用、DoH 超时与 TLS 校验、ECH 双初始化、`_mode` 回退与 `portNotifier`、下载 URL 是否走代理/直连同源 |
| **3** | API/存储/模型 | `lib/api/twitter_api.dart`、`lib/models/user.dart`、`lib/services/storage_service.dart`、`lib/utils/stable_hash.dart`、`lib/screens/ranking_screen.dart`、`test/user_model_test.dart`、`test/storage_service_test.dart`、`test/stable_hash_test.dart` | 832 | `fromJson` 容错（禁裸 `as`）、`resp.data` 类型判定、缓存并发去重与 TTL、写后清缓存、加载失败不得静默吞、错误态与空数据态可区分 |
| **4** | 入口/导航/主题 | `lib/main.dart` | 413 | Tab 重建策略（`IndexedStack` + `ValueKey` 权衡）、`runZonedGuarded`/`FlutterError.onError`、初始化失败白屏、`ThemeData` 是否每次 build 重建、双层 Scaffold/AppBar |
| **5** | 列表/收藏/搜索 | `lib/screens/user_list_screen.dart`、`lib/widgets/fav_list.dart`、`lib/widgets/search_bar.dart` | 1004 | `ValueKey` 与数据去重一致性、失败态是否有重试入口、in-flight 守卫、`onRefresh` 语义、handle 正则校验、`catchError((_) => [])` 吞错误 |
| **6** | 详情/标签/下载 | `lib/screens/user_detail_screen.dart`、`lib/widgets/tag_controller.dart`、`lib/widgets/tag_display_area.dart`、`lib/widgets/tag_selector_modal.dart`、`lib/widgets/horizontal_button_row.dart`、`test/tag_display_area_test.dart` | 1018 | Android 下载目录（禁硬编码公共路径）、`RandomAccessFile` finally、`HttpClient` 超时、`didUpdateWidget` 全量同步、乐观更新回滚、默认值不得每次启动覆盖用户值、`(e.value as num)` 强转 |
| **7** | 图片组件 | `lib/widgets/twitter_image.dart` | 485 | Hero tag 唯一性、`errorBuilder` 内 `setState`（build 期间）、下载超时、`cacheWidth/cacheHeight`、回退模式与下载同源 |
| **8** | 视频组件 | `lib/widgets/twitter_video.dart` | 797 | **必须独占一段**：两个 State 类（`_TwitterVideoState` / `_FullscreenVideoState`）的方法可见性最易出错。重点：`await` 后判 `mounted`、`didUpdateWidget` 需 `_initSeq` 序号、controller 泄漏、下载防重入、全屏锁横屏与速度同步 |
| **9** | 设置页 | `lib/screens/settings_screen.dart` | 236 | `embedded` 参数与外层工具栏、清除数据作用域、日志弹窗空安全、状态卡刷新时机、二次确认与重入保护 |

**已知真空（不得再遗漏）**：`test/` 全部 6 个测试文件、`.github/workflows/native_ech_poc.yml`、`ech-proxy/main.go`。

## 强制依赖顺序

```
段 1 (CI/Go 基线) → 段 2 (代理层，8 个消费方) → 段 3 (数据模型契约)
  → 段 4/5/6/7/8 (并列) → 段 9
```

- 段 2 改 `proxy_manager` 公开 API 时，**段 4/5/6/7/8/9 的结论全部失效**，需通知重审。
- 段 3 改 `user.dart` 字段语义时，段 5/6/8 对"字段缺失"的判断依据随之变化。
- 段 1 改 `go.mod` / `pubspec` / CI 触发条件时，所有段的验证前提变化。

## 子 agent 产出格式（强制）

只读（禁止写文件），每条发现必须包含：

```
级别 [H|M|L]  文件:行号  函数/构造器名
现状：<当前代码片段或行为>
问题：<为什么错，什么条件下触发>
建议：<可编译的代码片段，不是自然语言描述>
```

级别定义：
- **H**：崩溃、功能完全不可用、数据丢失
- **M**：功能缺陷、错误被静默吞掉、状态不一致
- **L**：性能浪费、死代码、风格/文案

**禁止只给"建议加 `if (!mounted) return`"这类纯文本建议**——父 agent 无法核对作用域、API 签名、const 规则，这正是上次 4 轮 CI 空转的根因。

子 agent 还应确认"无问题的点"，避免父 agent 重复排查。

## 父 agent 执行流程

1. **并行派发**（8 个 `subagent` / `subagent_fork`，只读指令写在 prompt 里）。
2. **收到报告后先修 H 级**，同文件的多条合并成一次编辑，减少往返。
3. **每批改完，推 tag 前做本地自检**（本会话无 Flutter SDK，见下）：
   ```bash
   # 括号配平（粗糙但能挡住结构性错误）
   for f in <改动文件>; do
     o=$(tr -cd '{' < "$f"|wc -c); c=$(tr -cd '}' < "$f"|wc -c)
     po=$(tr -cd '(' < "$f"|wc -c); pc=$(tr -cd ')' < "$f"|wc -c)
     echo "$f {}:$o/$c ():$po/$pc $([ "$o" = "$c" ] && [ "$po" = "$pc" ] && echo OK || echo MISMATCH)"
   done
   ```
   再人工核对：新增方法是否属于当前 State 类、`ValueListenable.addListener` 回调是否 `VoidCallback`、const 规则、新增 import 是否存在。
4. **Go 侧本地验证**（本地有 Go，可当场编译）：
   ```bash
   cd ech-proxy
   gofmt -l cmd/ech-flutter-shared/main.go
   CGO_ENABLED=1 go build -buildmode=c-shared -o /tmp/libechproxy_test.so ./cmd/ech-flutter-shared/
   nm -D /tmp/libechproxy_test.so | grep -E " T (ECH|Free|Get|Is|Start|Stop)"
   # 期望 12 个：ECHGetLog ECHGetLogCount ECHInit ECHInitLastError ECHInitReady
   # ECHInitWithBootstrap ECHSetDohURL FreeCString GetProxyPort IsEchReady StartProxy StopProxy
   ```
5. **提交 + 推 tag**（CI 只在 `main` 分支和 `v*` tag 触发，推分支无效）：
   ```bash
   TAG="v$(date -u +%Y%m%d.%H%M%S)"
   git tag "$TAG"
   git push origin feat/native-ech-poc "$TAG"
   ```
   日期 tag 由 `build.yml` 转成 `YYYYMMDD.0.HHMMSS`（Flutter 要求三段版本）。
6. **读完整 CI 日志**：不能只看 run 顶层状态，必须 grep 全 log 的
   `error •` / `Error:` 行——顶层可能显示 success 而 `flutter_test` 质量门已失败。
   ```bash
   gh run view <id> --log 2>&1 | grep -iE "error •|Error:"
   ```
7. 全绿后**再开下一批**。一轮 build.yml 约 6 分钟，串行推 tag 会把等待变成乘积：
   上次 7 次 push、其中 4 轮因编译错误完全空转（约 24 分钟）。**尽量把一批修完再推**。

## 环境限制（影响验证手段）

| 项 | 状态 | 影响 |
|----|------|------|
| Flutter / Dart SDK | **无**（`flutter: command not found`） | 无法本地 `flutter analyze` / `flutter test`，Dart 静态分析只能靠 CI |
| Go | 可用 | Go 侧可当场编译 + 检查导出符号 |
| CI 触发 | 仅 `main` 分支 + `v*` tag | 推分支不触发任何构建 |
| CI 时长 | build.yml ~6 分钟，ech-proxy APK ~3 分钟 | 每次验证成本高，批量化提交 |
| Flutter 版本 | 3.44.3（Dart < 3.5.0） | 见下方已验证的编译陷阱 |

## 已实证的编译陷阱（写代码前先查）

这些是本轮实际炸过 CI 的，直接照抄避免重犯：

- `HttpClientResponse` **既无 `close()` 也无 `cancel()`**——它是纯 `Stream<Uint8List>`。
  响应流不需要单独关闭，连接由外层 `client.close()` 统一释放。
- `ValueListenable<T>.addListener` 需要 `VoidCallback`（`void Function()`），
  不能传 `void Function(int?)`。
- Flutter 3.44 的 `AppBar` **不接受 const 字面量**：写 `AppBar(title: const Text('设置'))`，
  不要写 `const AppBar(title: Text('设置'))`。
- `_buildUrl()` 这类方法只属于定义它的 State 类：
  `_TwitterVideoState` 的方法在 `_FullscreenVideoState` 里不可见，全屏版要另写局部判断。
- `CardThemeData`（非 `CardTheme`）；`Icons.*_outlined`（非 `*_outline`）；
  `Container` / `Icon` 构造函数**非 const**。
- `FadeTransition.opacity` 需要 `Animation<double>`：
  用 `CurvedAnimation(parent: a, curve: ...)` 取 `.value`，不要 `Curves.x.transform(a)`。
- `await` 之后必须判 `mounted` 再 `setState` / `addListener`。
- `await for (var x in stream)` 要求 stream 非空：nullable 变量要用非空局部变量承接。
- Android 下载目录**不得硬编码** `/storage/emulated/0/Download`
  （targetSdk 34 分区存储下 `Directory.create()` 抛 Permission denied）。
- `am start -d` 需要 `file://` URI，裸路径打不开目录。
- 批量下载前给 `HttpClient` 设 `connectionTimeout`，否则代理挂死时 UI 永久卡"下载中"。
- 写文件用 `RandomAccessFile` 必须 `finally` 关闭，失败时删除半写文件。
- 列表 `ValueKey(u.username)` 必须与数据去重配套，否则 `Duplicate keys` 断言崩溃。
- `fromJson` 不用裸 `as`：抽 `_str` / `_int` / `_list` / `_map` 容错辅助。
- Go 代理 handler 拼 URL 用 `normalizePath(path)` 统一前导斜杠，
  兼容调用方传 `"/media/x"` 和 `"media/x"` 两种形式（否则会拼出 `//media/x`，WAF 403）。
  **只有 `ech-flutter-shared` 一个入口**（浏览器版 demo APK 已移除）。

## 剩余待修（2026-09-10 未修完的 ~35 个 M/L）

按段归属，下一轮直接派对应段：

- **段 2**：`proxyMu` 持锁跨 ECH 同步校验（UI 冻结数十秒）、`catch(_)` 吞 `lookupFunction`
  错误后误报 "update libechproxy.so"、DoH 无超时 + 盲信 TLS、ECH 双初始化致 restart 失效、
  `ech_url.dart` 端口 0 与 `uri.query` 重编码签名 CDN URL
- **段 8**：`didUpdateWidget` 无 `_initSeq` 序号（旧 in-flight 写已释放 controller）、
  initialize 失败未 dispose controller、全屏未锁横屏、全屏速度未从 controller 初始化、
  Hero tag 依赖 url 全局唯一、`errorBuilder` 内 `setState`
- **段 5**：`_UserTile` 失败仅置 `_loading=false` 无重试入口、`_AddUserTile` 双击并发发两次、
  `fav_list` 无 key、`onRefresh` 假刷新、handle 无正则校验、`catchError((_) => [])` 吞错误
- **段 6**：代理未启动静默 `return false` 只报"成功 0/10"、标签乐观更新不回滚、
  `(e.value as num)` 强转
- **段 3**：`storage_service` 加载失败静默吞、ranking 错误态与空数据态不可区分、
  `_loadingUser` 死状态、`.tmp` 残留无清理
- **段 9**：`_clearData` 未清图片缓存与本地下载、状态卡不随代理状态刷新、
  重启无二次确认、日志弹窗无刷新/复制、Windows 端 `double.maxFinite` 宽
- **段 1**：两个 workflow 同 tag 抢建 Release、ech-proxy APK 产物是 `assembleDebug`、
  `android/` 空目录未跟踪、main 分支 push 也会造 Release、bump_version.sh 推 main
