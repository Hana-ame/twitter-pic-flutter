# Twitter Pic Flutter — AI Agent 协同与工程维护指南

> **适用对象**：所有参与此仓库设计、编码、重构、排查与 CI/CD 维护的 AI 编程助手（Agent）。
> **适用版本**：v0.8.0+（Flutter `3.44.3` / Dart SDK `^3.12.0`）。
> **核心原则**：严守全链路 ECH 代理隔离（控制面与数据面均不静默回退直连）、严防 N+1 与阻塞式拉取、维护跨端与跨屏唯一真相源、测试状态严格隔离、以云端 GitHub Actions 作为唯一验收裁判。

---

## 1. 网络架构铁律：双通道共用本机 ECH 代理

本项目控制面（`x.moonchan.xyz`）与数据面（`pbs.twimg.com` / `video.twimg.com`）在墙内均不可直连，**两条通道统一经本机 Go ECH 代理转发**（详见 [doc/architecture.md](doc/architecture.md) 与 [doc/troubleshooting.md](doc/troubleshooting.md)）：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Flutter / Dart 业务层                            │
└──────────────────────────┬──────────────────────────────┬───────────────┘
                           │                              │
       控制面（API/JSON）   │                              │ 数据面（图片/头像/视频）
  TwitterApi.setProxyPort  │                              │ EchUrl.rewrite(url, port)
                           ▼                              ▼
        http://127.0.0.1:<port>/api/...      http://127.0.0.1:<port>/<path>?<query>
                           │                              │
┌──────────────────────────▼──────────────────────────────▼───────────────┐
│        本机 Go ECH 代理（进程内 c-shared：libechproxy.so / echproxy.dll）  │
│        来源：Hana-ame/ech-proxy（CI 按 ECH_PROXY_REF 钉定 tag 拉取编译）   │
│        监听明文 HTTP（127.0.0.1:8443，冲突回退 :0 随机端口）               │
├──────────────────────────────────────────┬──────────────────────────────┤
│  /api/* → apiProxyHandler (ECH 隧道)      │ 其余路径 → echProxyHandler    │
│  → https://x.moonchan.xyz/api/...        │ → https://video-cf.twimg.com │
└──────────────────────────────────────────┴──────────────────────────────┘
```

### 1.1 控制面（`lib/api/twitter_api.dart`）
- **两套 Base，严禁混用**：
  - 根 API：`kApiBase = 'https://x.moonchan.xyz/api/twitter'`（用户列表、详情 `alice.json.gz`、标签、emoji、排行）。
  - 图站 API：`kGalleryBase = 'https://x.moonchan.xyz'`（`/api/tag/<tag>`、`/api/tag-cloud`、`/api/tags` 等）。
  - **⚠️ 路由红线**：图站标签端点挂在 `galleryMux` 上，**不带** `/api/twitter` 前缀；误拼为 `/api/twitter/tag/<tag>` 会静默 404。
- **代理注册与等待语义（禁止静默直连）**：
  - `main.dart` 在代理启动成功后调用 `TwitterApi.setProxyPort(port)`，由 Dio 拦截器把 `x.moonchan.xyz` 改写为 `http://127.0.0.1:<port>`。
  - 端口为 `null` 时请求挂起等待代理就绪（`proxyWaitTimeout = 30s`，超时抛 `NetworkException`），**绝不回退直连**。测试注入假适配器时默认关闭等待（可用 `TwitterApi.debugRequireProxy` 显式控制）。
- **Dio 路径拼接与异常解包**：
  - Dio 拼接 `baseUrl + path` 不会自动补斜杠，所有 path 必须以 `/` 开头（并保留 `onRequest` 拦截器归一化）。
  - **判断 HTTP 状态码必须用 `asHttpException(e)`**，严禁直接写 `e is HttpException`（拦截器将 `HttpException` 包装在 `DioException.error` 内）。

### 1.2 数据面（`lib/utils/ech_url.dart`）
- Dart 侧所有图片、头像、视频必须经 `EchUrl.rewrite(url, port)` / `EchUrl.rewriteToUri(url, port)` 改写为 `http://127.0.0.1:<port>/<path>?<query>`：
  - **丢弃原始域名**：上游统一拼到 `https://video-cf.twimg.com`，保留原 host 会 404。
  - **保留完整 Query**：丢失 `format=` / `name=` / `token=` 会导致 404 或 403。
  - **`port == null` 严禁回退直连**：抛出 `VideoProxyNotReady` 或明确提示“代理未就绪”。
- **Android 明文放行范围**：CI 在构建时生成 `res/xml/network_security_config.xml`，**仅对 `127.0.0.1` 和 `localhost` 放行明文 HTTP**（不对公网域名开放全局 `usesCleartextTraffic`），并在 `AndroidManifest.xml` 中注入与硬校验。
- **ECH 原生库管理**：本仓库**不再保留 `ech-proxy/` 源码副本**，由 `.github/workflows/build.yml` 中的 `ECH_PROXY_REF`（当前 `flutter-lib-v1.0.2`）从 `Hana-ame/ech-proxy` 拉取并编译，编译后强制校验 12/12 个 FFI 导出符号。

---

## 2. 列表性能、标签契约与状态唯一真相源

### 2.1 禁止阻塞式全量拉取元数据（防 N+1 / Hydrate 冻结）
- 首页列表（`getUserList`）与标签翻页（`getUsersByTagPage`）响应后**必须立即渲染**，严禁在翻页时阻塞等待全页 20~25 个 `.json.gz` 下载。
- 标签翻页优先使用服务端 V2 富卡片结果（`TagUserPage.users` 与 `hasMore`），旧版裸用户名接口 `/api/tag/<tag>` + 批量权重 `/api/tags?keys=...` 仅作回退路径。
- 已知 404 幽灵账号由 `TwitterApi.isKnownMissing(username)` 做 30 分钟负缓存，避免翻页重复打注定 404 的请求；正缓存 `getMetaData` 为 10 分钟 TTL + in-flight Future 去重。

### 2.2 过滤与隐藏判定唯一真相源（`lib/services/storage_service.dart`）
- **列表隐藏判定一律调用 `StorageService.shouldHideUser(username, tags)`**，严禁在各页面分别手写过滤逻辑。它统一合并三条本地规则：
  1. 用户名屏蔽（`block-map`）；
  2. 正权重屏蔽标签命中（`blockTagHits`，负分/0 分不触发；Gay 模式下与 Gay 词表重叠的标签不触发屏蔽）；
  3. Gay 模式匹配（`matchesGayMode`：关闭时隐藏含正权重 Gay 标签的用户，开启时仅显示含正权重 Gay 标签的用户）。
- **标签权重过滤契约**：标签反查与详情页均只认正权重（`score > 0`），负分与 0 分不展示 chip、不作为反查命中。
- **跨端词表契约**：`StorageService.kDefaultGayTags = ['男性', '男娘', '人妖', '露屌', '阳痿', '男同']` 与图站 `gallery/static/home.js` 的 `DEFAULT_GAY_TAGS` 必须逐项一致（由 `test/gay_tag_contract_test.dart` 锁定）。
- **跨 Tab 状态同步**：首页 Tab 挂在 `IndexedStack` 中会被保活；修改收藏、屏蔽、Gay 模式、标签规则或视频兼容模式后，统一通过 `StorageService.changes`（`ValueNotifier<int>`）通知保活页面同步刷新。
- **详情页标签跳转句柄**：`UserDetailScreen.tagBrowse` 为 `required` 的可空回调；来自用户列表页时必须透传，来自无列表页可递回的入口（如 `FavoritesTab`）必须显式传 `null` 并给用户明确提示。

---

## 3. 图片与视频播放规范

### 3.1 图片加载与全屏相册
- **双档位分工（`lib/utils/media_url.dart`）**：列表卡片与详情页预取统一用 `MediaUrl.thumbOf(url)`（`name=small`，只改 `name=`、绝不破坏其他 query 参数或重复键签名），全屏预览与下载分享保持 `orig` 原图。
- **逐块流式解码 + 磁盘缓存**：图片统一走 `ProgressiveImageProvider`（含 `ProgressiveDiskCache` 磁盘缓存与启动时放宽的 160MB / 1500 张内存 `ImageCache`）。
- **全屏相册依赖纪律**：使用 `photo_view`（零网络依赖），**严禁换用自带独立 HTTP 栈的图片库**（如 `extended_image`），防止在结构上绕过 ECH 代理。
- **布局红线**：列表图片必须用 `AspectRatio` 给出确定高度，严禁在无界高度的 `ListView` item 内使用 `Stack(fit: StackFit.expand)`。

### 3.2 视频播放、解码器池与兼容模式
- **代理前置要求**：本机代理必须透传 `Range` 并返回 `206 Partial Content`，且强制 `Accept-Encoding: identity`（防止 Go transport 自动 gzip 删除 `Content-Length`）。
- **依赖与软硬解回退（`pubspec.yaml`）**：
  - `video_player: ">=2.12.0 <2.15.0"`（上界不可随意放宽，需与 Android fork 的平台接口 `^6.9.0` 配套）。
  - `dependency_overrides` 将 `video_player_android` 钉在 `Hana-ame/video_player_android`（`ref: 2.12.2-fallback.2`），通过 `CompatRenderersFactory` 支持 `auto` / `smart`（非 16 对齐分辨率优先软解、标准分辨率保持硬解）/ `prefer_software`（软解排前、保留硬解回退）/ `hardware_only`，并通过 `AnalyticsListener.onVideoDecoderInitialized` + `DecoderTelemetry` 在不改 Pigeon 协议的前提下上报实际选中的解码器名。
- **解码策略与并发池（`lib/video/decoder_policy.dart` / `lib/video/video_decoder_pool.dart`）**：
  - 开启软解回退后，能上抛到 Dart 层的 MediaCodec 错误意味着软硬解双双失败，由 `DecoderPolicy.classify` 判 `failFast`（不降档、不自动重排）；仅网络/代理类抖动走一次性自动重试。
  - 并发上限按最坏全软解负载约束在 `1~3`（连击 4 次成功上调并存档至 `StorageService`）。
  - 视频封面优先级：磁盘缓存 `PosterService` → 服务端 `cover` 字段（`MediaUrl.thumbOf`）→ `MediaUrl.videoPosterOf` 推导 → `RepaintBoundary.toImage()` 离屏抓帧（含 `isMostlyBlack` 黑帧校验）。
- **视频播放兼容模式（`lib/video/video_compat_mode.dart`）**：
  - 为解决部分 Android 机型（见 `flutter/flutter#174026`、`#185674`）在 Media3 下播放非 16 对齐分辨率视频时，由硬件解码器输出 stride 与 Impeller `ImageReaderSurfaceProducer` 纹理采样不匹配导致的**画面斜切、绿色斜纹**，在设置页与视频长按/错误菜单中提供 **5 种预设模式（1 个标准 + 4 个兼容）**，全部保持流式起播：
    1. `standard`（**默认**，「标准模式（auto）」）：`textureView` + 原生 `auto` —— 全程有硬解就用硬解，硬解失败才回退软解。**完全不动解码器顺序**，正常机型行为与改动前一致。
    2. `smartSoftware`（「兼容 1：智能软解（smart）」）：`textureView` + 原生 `smart` —— 仅当宽或高不能被 16 整除时把软解排到硬解前面；标准分辨率（720p/1080p）仍走硬解。
    3. `platformView`（「兼容 2：原生视图（PlatformView + auto）」）：Android 切 `VideoViewType.platformView`（原生 `SurfaceView`）绕过 Impeller 纹理路径；解码仍是 `auto`（有硬解就用硬解），不影响正常机型。跳过对 PlatformView 无效的离屏抓帧。
    4. `preferSoftware`（「兼容 3：优先软解（prefer_software）」）：`textureView` + 原生 `prefer_software`，并发上限锁 `1`。
    5. `platformViewSoftware`（「兼容 4：原生视图 + 优先软解（prefer_software）」）：`platformView` + `prefer_software`，并锁并发 `1`。
  - **铁律：兼容模式只「重排优先级」，绝不「删掉硬解」。** 原生 `CompatRenderersFactory.preferSoftwareOrder()` 从 `MediaCodecSelector.DEFAULT` 取**全量**解码器，仅把 `MediaCodecInfo.softwareOnly` 的分到前段、硬解分到后段再拼回；软解列表为空时原样返回。因此 3/4 模式下软解解不了的格式仍会自动回退硬解 —— 不存在「开了兼容反而更解不了」。改这块时必须守住：**不许使用 `MediaCodecSelector.PREFER_SOFTWARE`**（那个会用 `softwareOnly=true` 单独查询，软解缺失时返回空列表，等于硬删硬解）。
  - 持久化键 `video-compat-mode` 存 `storageKey`（`standard` / `smart_software` / …），解析统一走 `videoCompatModeFromStorage`：兼容 v0.7.x 旧键（`software_decode` / `single_decoder` / `software_platform_view` / `local_file`），未知值安全回退 `standard`。
  - 单路硬上限由 `VideoDecoderPool(maxOverride: …)` 提供：一旦存在显式覆盖，`captureUnavailable` 的解锁逻辑**不得**突破它（软解用 CPU，多路同解会互相拖垮）。
  - **跨平台注意**：Windows 端（`video_player_win`）通过 `effectiveViewType(isAndroid: Platform.isAndroid)` 始终回退为 `VideoViewType.textureView`；Android 端通过 `VideoCompatChannel.getLastDecoderSummary()` 把实际选中的解码器名写进日志与反馈包。
- **渲染红线**：
  - 视频卡片与全屏页使用 `Center + AspectRatio + VideoPlayer`，严禁使用 `FittedBox` 量测 `VideoPlayer`（`TextureBox.sizedByParent` 在无界约束下会黑屏）。
  - 同一个 `VideoPlayerController` 同一时刻只允许一个 `VideoPlayer` 渲染（进入全屏时卡片侧必须切换为纯黑占位 `_fullscreenOpen`）。

---

## 4. 测试、静态检查与 CI 质量门禁

> **环境约定**：本地无 Flutter SDK 时，所有静态检查、测试与双端构建均以云端 GitHub Actions（`.github/workflows/build.yml`）为唯一裁判。

### 4.1 静态分析（Analyze Gate）
```bash
flutter analyze --no-fatal-infos
```
- **⚠️ 注意**：CI **未**加 `--no-fatal-warnings`，**任何 Error 或 Warning 都会直接导致 CI 红**（仅 Info 放行）。`analysis_options.yaml` 启用了 `flutter_lints`、`prefer_const_constructors` 与 `prefer_const_declarations`。

### 4.2 全量测试与覆盖率门槛
```bash
flutter test --coverage
```
- 仓库现有 **37+ 个测试文件**，验收必须以**整包 `flutter test --coverage`** 为准（逐文件隔离绿不构成验收，跨文件进程级 static 状态串味只有在整包运行中才会暴露）。
- CI 强制校验 `coverage/lcov.info` 非空、包含有效 `SF:`/`DA:`/`end_of_record`，且**行覆盖率不得低于 40.00%**（基线 46.46%）。
- 禁止在含无限动画/骨架屏的页面测试中无脑调用 `pumpAndSettle()`，必须使用有界 `tester.pump(const Duration(milliseconds: 100))` 循环。

### 4.3 进程级静态状态隔离铁律（CI 自动反推检查）
CI 的 `Storage-writing tests must reset static state` 步骤会直接从 `lib/services/storage_service.dart` 源码反推所有公共写方法（`set*` / `save*` / `toggle*` / `add*` / `remove*` / `reset*` / `clear*`），并同步检查以下五个静态状态家族：
- `StorageService.resetForTests()`
- `TwitterApi.resetForTests()`
- `LogService.resetForTests()`
- `PosterService.resetForTests()`
- `ProgressiveDiskCache.resetForTests()`

**凡是在测试中调用了上述任一类的写方法，必须在 `setUp` / `tearDown` 中调用对应的 `resetForTests()`**，否则 CI 静态闸门直接失败。修改 CI 中的 shell 脚本时，必须使用 POSIX `sh`（`dash`）兼容正则验证。

---

## 5. 构建、版本与发布流程（`.github/workflows/build.yml`）

```
PR to main         ──► flutter_test（静态分析 + 静态隔离检查 + 整包测试 + 40% 覆盖率门禁）
Push main / tag    ──► flutter_test ──┬──► build_android（NDK r27 + Go c-shared + APK arm64）
                                      ├──► build_windows（Go c-shared DLL + Windows x64 zip）
                                      └──► create_release（仅 semver tag 发正式 Release + SHA256SUMS.txt）
```

### 5.1 发版规则
- **平台脚手架隔离**：仓库不提交 `android/`、`ios/`、`windows/` 目录，CI 通过 `flutter create` 现场生成并注入包名 `xyz.moonchan.twitterpic`、权限、图标与 `network_security_config.xml`。
- **版本号更新**：可修改 `pubspec.yaml` 或运行 `./bump_version.sh [--push]`。
- **正式 Release 触发条件**：仅严格匹配 `^v[0-9]+\.[0-9]+\.[0-9]+$` 的 semver tag 会发布正式 GitHub Release（附带 `app-release.apk`、`twitter_pic_flutter_windows_amd64.zip` 与 `SHA256SUMS.txt`）。
- **测试包 / 日期 tag**：非 semver tag（如 `v0.8.1-test-issue12` 或 `vYYYYMMDD.HHMMSS`）只构建并保留 workflow artifacts，不污染正式 Release 列表。

---

## 6. Issue 处理流程

**分两种来源，流程不同：**

| issue 提出者 | 流程 |
|---|---|
| **Hana-ame 本人** | 直接修 → PR（确认 `flutter_test` 绿）→ 合并 → 打 semver tag 发版 |
| **非 Hana-ame**（其他用户） | ① 在分支实现 → ② CI 出**测试包** → ③ 在 issue 回复**下载链接 + 修改位置 + 测试步骤** → ④ **等提出者实测回复 OK 后再合并发版** |

**非本人 issue 操作细节：**
1. 从 `main` 拉分支实现修复，版本号 +0.0.1（确保测试包可辨认）。
2. 推送非 semver 测试 tag `v<版本>-test-issue<N>` 触发 CI 产出 artifact，再用 `gh release create <tag> --prerelease` 附上 APK / Windows zip 生成公开下载链接。
3. Issue 回复必须写清：测试包下载链接、改动文件与层级、具体测试步骤与已知限制，以及有歧义处的实现口径。
4. 提出者回复 OK 前不合并 PR、不打正式版 tag；若需继续调整，在同一分支迭代并重推测试 tag。
