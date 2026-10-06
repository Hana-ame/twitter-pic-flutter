# Twitter Pic Flutter — AI Agent 协同与工程维护指南

> **适用对象**：所有参与此仓库设计、编码、重构、排查与 CI/CD 维护的 AI 编程助手（Agent）。
> **核心原则**：严谨尊重既有架构铁律、严防性能退化（拒绝任何阻塞式请求）、测试先行与跨用例状态隔离、发布即打 Tag 并由云端 CI 构建双端产物。

---

## 1. 架构核心铁律与双网络通道隔离

本项目必须严格遵循**双网络通道物理隔离**设计（详见 [doc/architecture.md](doc/architecture.md) 与 [doc/troubleshooting.md](doc/troubleshooting.md)）：

```
┌─────────────────────────────────────────────────────────────────┐
│                      Flutter / Dart 业务层                       │
└────────────────────────┬──────────────────────┬─────────────────┘
                         │                      │
       控制面：直连 API   │                      │ 数据面：媒体直走本地代理
       (绝不进入代理)     │                      │ (EchUrl.rewrite 改写)
                         ▼                      ▼
           https://x.moonchan.xyz          http://127.0.0.1:<port>
           ├── /api/twitter/...                   │ (明文 HTTP，原生 cgo 库)
           └── /api/tag/...                       │
                                                  ▼ (TLS 1.3 + ECH 混淆 SNI)
                                           https://video-cf.twimg.com
                                           (pbs.twimg.com 与 video.twimg.com)
```

### 1.1 控制面：API 直连（严禁进代理）
- **根 API 端点**：`kApiBase = 'https://x.moonchan.xyz/api/twitter'`（用户列表、详情元数据 `alice.json.gz`、emoji、排行）。
- **图站 API 端点**：`kGalleryBase = 'https://x.moonchan.xyz'`（`/api/tag/<tag>`、`/api/tag-cloud`、`/api/tags`）。
  - **⚠️ 路由警告**：标签端点挂在图站自身的 `galleryMux` 上，路径**不带** `/api/twitter` 前缀。请求写成 `/api/twitter/tag/<tag>` 会直接返回 404（路由不存在）。
- **Dio 路径拼接**：Dio 拼接 `baseUrl + path` 时**不会自动补前导斜杠**，必须保持前导 `/` 或依赖 `onRequest` 拦截器归一化，否则会拼接成 `...xyz/api/twitteralice.json.gz` 导致 403 事故。

### 1.2 数据面：媒体走 ECH 代理
- Twitter CDN（`pbs.twimg.com`, `video.twimg.com`）在国内受 SNI 干扰拦截。
- Dart 侧所有图片和视频必须通过 `EchUrl.rewrite(url, port)` 改写为 `http://127.0.0.1:<port>/...`。
  - **丢弃域名**：代理上游统一硬编码 `video-cf.twimg.com`，如果保留原始 host 会导致路径拼错 404。
  - **保留完整 Query**：丢弃 query（如 `format=jpg&name=orig`）会导致资源 404。
  - **代理未就绪不可静默回退直连**：直连必死（实测 000/超时），`port == null` 时必须显式向上抛错或展示“代理未就绪”，绝不允许静默 fallback 回直连。

---

## 2. API 真实口径与性能红线（血泪教训）

### 2.1 严禁在列表与翻页时阻塞全量拉取元数据（Hydrate 陷阱）
- **性能红线**：
  - 首页列表（`getUserList`）和标签列表（`getUsersByTagPage`）在翻页或初次加载时，**绝对禁止调用阻塞式 `hydrateUsernames` 等待全量 20~25 个 `.json.gz` 下载**！
  - 每个用户的 `.json.gz` 包含完整 timeline，单页若串行/并发下载 25 个，在弱网或幽灵账号下需阻塞 10~15 秒，导致严重的界面冻结卡顿。
- **正确的加载范式（0.5.x 秒开架构）**：
  1. 列表接口响应后**立即渲染**；
  2. 头像与昵称由 `_UserTile` 在进入视口（Viewport）后，通过 `didUpdateWidget` / `initState` 异步按需拉取；
  3. `_UserTile` 复用元数据内存缓存（`TwitterApi.getMetaData` 内置 10 分钟 TTL 与 in-flight 抑制），已含昵称/头像的条目零网络请求渲染。

### 2.2 幽灵账号、404 负缓存与标签权重过滤
- **幽灵账号与 404**：
  - 图站标签反查接口 `/api/tag/<tag>` 返回的裸用户名列表中，存在大量已注销、被封禁或无推文的“幽灵账号”。
  - 请求对应用户的 `GET /api/twitter/<username>.json.gz` 会直接返回 HTTP 404。
  - 必须通过 `TwitterApi.isKnownMissing(username)` 进行**负缓存**，404 账号记录后不再重复发起请求。
- **批量标签权重与过滤口径**：
  - 标签反查页使用单次批量端点：`_api.getTagWeightsBatch(page.usernames)`（调用 `GET /api/tags?keys=u1,u2...`）。
  - **过滤规则**：
    1. 服务端省略该键的用户（即 banned 或不在 tags.db 中的幽灵账号），直接剔除；
    2. 已在 `TwitterApi.isKnownMissing` 中的已知 404 账号，直接剔除；
    3. **标签票数过滤契约（v0.7.10 裁决）**：当前标签列表仅展示真正支持该标签的用户（`(w[tag] ?? 0) > 0`）；对于反对票或投票 `<= 0` 的账号不出现在该标签反查结果中。详情页展示口径保持一致：负权标签不展示 chip，但用户主页正常。
- **后台并发预热（Prewarm Meta）机制**：
  - 列表秒开后，`_load` / `_appendUsers` 采用 fire-and-forget 异步预热前 12 个账号的元数据。
  - 受控并发度为 6（避免撞击服务端 25rps 限速触发 429 降级）。
  - 利用 `TwitterApi.getMetaData` 缓存 Future 的特性，预热中的请求与列表行内懒加载无缝共享同一网络 Future，做到绝不重复请求。

---

## 3. 视频与图片播放/渲染规范

1. **图片一律使用原图 origin**：
   - 线上已废弃 `name=` 尺寸档位划分（会打乱缓存 key），图片 URL 必须统一保持 origin 原图请求。
   - 图片使用 `ProgressiveImageProvider`（逐块流式解码），`AspectRatio` 必须在首帧前预设占位（默认 3:4），**严禁在 `ListView` 中对图片使用 `Stack(fit: StackFit.expand)`**（无界高度传入紧约束会导致整屏空白崩溃）。
2. **视频播放与解码器槽位控制**：
   - ExoPlayer 必须要求本地代理支持 `Range` 请求并返回 `206 Partial Content`，代理必须强制 `Accept-Encoding: identity`（禁止 Go transport 自动 gzip 删除 Content-Length）。
   - 视频卡片必须使用 `Center + AspectRatio + VideoPlayer`，**严禁在无界约束中使用 `FittedBox` 量测 `TextureBox`**（会导致全屏黑屏）。
   - 软硬解回退（`VideoDecoderPool`）：受 Android MediaCodec 硬件解码器槽位限制，池化管理并发数（1~3），避免硬解崩溃。

---

## 4. 测试与验证工作流（发布前铁门槛）

本地若无 Flutter SDK 或处于特定环境，也可通过容器或云端 CI 验证。当本地有环境时，在提交前必须依次执行：

### 4.1 静态检查（Analyze Gate）
```bash
flutter analyze --no-fatal-infos --no-fatal-warnings
```
- 必须做到 **0 错误**（Error = 0）。

### 4.2 单元与组件测试（Test Suite）
```bash
# 核心标签与列表规约测试
flutter test test/tag_rule_consistency_test.dart test/user_list_no_nplus1_test.dart test/gallery_tag_paging_test.dart test/filter_by_tag_test.dart

# 核心媒体与解码策略测试
flutter test test/ech_url_test.dart test/frame_luma_test.dart test/media_url_test.dart test/decoder_policy_test.dart

# 全套整包测试（CI 验收闸门）
flutter test
```

### 4.3 测试编写特别防坑规约（状态隔离铁律）
- **`StorageService` 进程级 static 状态隔离**：
  - 任何调用了 `StorageService` 写方法（或 `TwitterApi`、`LogService` 静态状态）的测试文件，**必须**在 `setUp` 与 `tearDown` 中显式调用：
    ```dart
    StorageService.resetForTests();
    ```
  - CI 中有专用静态检查脚本 `Storage-writing tests must reset static state`，未重置静态状态将直接导致 CI 红。
- **禁止在测试中使用无界动画 / 无脑 `pumpAndSettle`**：
  - 页面中若存在骨架屏动画（`AnimationController.repeat`）或下拉刷新，`pumpAndSettle` 会永久挂死直至 30 分钟超时。
  - 测试推进必须使用有界的 `await tester.pump(const Duration(milliseconds: 100));` 循环。

---

## 5. 版本发布与 CI/CD 流程

本项目采用自动化 GitHub Actions 持续集成与发布体系（`.github/workflows/build.yml`）：

```
Git Tag (v*) Pushed ────► 1. flutter_test (静态分析 + 114+ 全量测试)
                              │ (全部通过)
                              ├──► 2. build_android (编译 cgo libechproxy.so + 构建 APK)
                              ├──► 3. build_windows (编译 cgo echproxy.dll + 构建 Win zip)
                              │
                              └──► 4. create_release (汇总产物自动发布 GitHub Release)
```

### 5.1 发版操作步骤
1. **修改版本号**：在 [pubspec.yaml](pubspec.yaml) 中更新 `version: X.Y.Z`。
2. **提交代码**：
   ```bash
   git add .
   git commit -m "feat/fix: 详细更新说明"
   ```
3. **打 Tag 并推送到远程**：
   ```bash
   git tag vX.Y.Z
   git push origin main
   git push origin vX.Y.Z
   ```
4. **监控 CI 执行**：推送 tag 将自动触发 GitHub Actions 的 `create_release` 流水线。可在 GitHub Actions 界面确认所有任务全绿并生成 Release。
