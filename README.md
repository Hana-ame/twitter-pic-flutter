# Twitter Pic Flutter

> Flutter 项目，通过 ECH 域前置绕过 SNI 阻断，浏览 Twitter 图片与视频。

## 项目背景

本地无 Flutter/Android SDK，**纯 GitHub Actions 云端构建**。

SNI 阻断问题：Dart 的 `SecureSocket` 不暴露 ECH config 注入接口，无法在 Dart 层直接实现 ECH。  
方案：**Go c-shared + dart:ffi**，将 Go ECH 客户端编译为 `.so`，Flutter 通过 `DynamicLibrary.open` 加载，直接 FFI 调用。无 HTTP 代理中间层，无端口监听。

## 技术栈

| 层级 | 技术 |
| --- | --- |
| 框架 | Flutter 3.44.3 (stable) |
| 语言 | Dart ^3.12.0 / Go 1.26 (ECH Proxy) |
| 主题 | Material 3 |
| 图标 | flutter_launcher_icons + Moonchan favicon |
| 网络 | Go c-shared ECH Client (dart:ffi 直调) |
| 构建 | GitHub Actions: NDK r27 + Go (stable) + Flutter 3.44.3 |
| 发布 | GitHub Releases (APK + Windows ZIP 自动上传) |

## 目录结构

```
lib/
├── api/
│   └── twitter_api.dart          # API 客户端 (search/元数据/标签/表情/排行)
├── models/
│   └── user.dart                 # 数据模型
├── screens/
│   ├── user_list_screen.dart     # 用户列表/搜索/收藏
│   ├── user_detail_screen.dart   # 用户详情 (图片/视频/表情投票/标签)
│   └── ranking_screen.dart       # 表情排行榜 (日/周/月)
├── services/
│   ├── proxy_manager.dart        # FFI 加载 libechproxy.so + init/异步 fetch/流式下载
│   └── storage_service.dart      # localStorage 封装 (收藏/屏蔽/标签规则)
├── widgets/
│   ├── twitter_image.dart        # 图片组件，ECH 异步加载
│   ├── twitter_video.dart        # 视频组件：ECH 流式下载 → 原地播放 + 封面
│   ├── proxy_avatar.dart         # 用户头像 (ECH 异步加载)
│   ├── tag_selector_modal.dart   # 标签选择器 (分类/自定义)
│   ├── tag_display_area.dart     # 标签展示
│   └── tag_controller.dart       # 高亮/屏蔽标签管理
└── main.dart                     # 入口 & ECH 初始化
```

## 架构

```
┌───────────────────────────────────────┐
│             APK 进程空间                │
│                                       │
│  Flutter App ──Isolate + FFI────── Go  │
│  (fetchAsync)    ECHFetch(url)     ECH │
│                    ← raw bytes    Client│
│                     Image.memory       │
│           或流式 ECHFetchBegin/Read     │
│             → spool 文件 → video_player│
└───────────────────────────┬───────────┘
                            │ TCP :443 with ECH
                  ┌─────────┴──────────┐
                  │ cloudflare-ech.com  │
                  │ TLS 1.3 + ECH      │
                  │ SNI=video-cf...    │
                  └─────────┬──────────┘
                            │
                  ┌─────────┴──────────┐
                  │ Twitter CDN         │
                  │ video-cf.twimg.com  │
                  └────────────────────┘
```

### 工作流程

1. App 启动 → `ProxyManager.init()` → FFI `ECHInit()` → goroutine 拉取 ECH 配置
2. 轮询 `ECHInitReady()`（最长 30s）：0=等待，1=就绪，-1=失败
3. `fetchAsync(url)` → `Isolate.run` → FFI `ECHFetch()` → Go 通过 cloudflare-ech.com 发起 ECH TLS 连接，获取资源
4. 图片：返回原始字节 → `Image.memory()`
5. 视频：`fetchToFileAsync` → 工作 isolate 内 `ECHFetchBegin`/`ECHRead` 分块读取（64KB buffer 写盘，内存占用恒定）→ 下载完成后 `video_player` 原地播放，并抽首帧做封面（`video_thumbnail`，仅 Android/iOS）

### ECH 初始化

- `ECHInit` 使用 mutex 状态机（非 `sync.Once`），失败后可重试
- 支持 `ECHInitWithBootstrap(host, ip)` 直接 IP 拨号 DoH 服务器
- 日志通过环形缓冲区暴露给 Dart（`ECHGetLogCount` / `ECHGetLog`）

### DoH 自举

Go 在 Android FFI 中系统 DNS 不可靠，由 Dart 通过 `InternetAddress.lookup` 解析 DoH 服务器 IP 后传给 Go：

```dart
final addr = await InternetAddress.lookup('moonchan.xyz');
proxy.init(dohHost: 'moonchan.xyz', dohBootstrapIP: addr.first.address);
```

DNS 回退链：System DNS → Tencent (119.29.29.29) → Alibaba (223.5.5.5)，5 次重试。

### 视频播放

- **流式下载**：视频通过 `ECHFetchBegin`/`ECHRead` 分块流式写盘（64KB buffer），不把整个 mp4 读进内存，大视频不再 OOM；下载在后台 isolate 进行，带 3 次重试，UI 不阻塞。
- **原地播放**：下载完成后用 `video_player` 原地播放本地文件（Windows 由 `video_player_win`/Media Foundation 实现），播放中按视频实际宽高比自适应显示，竖屏视频不被拉伸。
- **封面**：下载完成后用 `video_thumbnail` 抽首帧做封面（仅 Android/iOS，桌面跳过）。
- **进度与缓存**：下载中显示已下载字节数；完成后写 `<spool>.done` 标记，同 URL 重进页面直接复用缓存。
- **控制栏**：播放中 3 秒无操作自动淡出（不挡画面），点视频唤出；时间按秒实时刷新。

> 边下边播（下载中播放本地流）经真机验证不可行，已移除：内置 ExoPlayer 对 chunked 本地流不稳定，系统播放器（open_filex）方案也无法可靠打开，统一为"下载完才能看"。

### 批量下载

用户详情页 header 提供三个下载入口，全部流式写盘到 `Download/<用户名>/`：
- **下载**：逐项 `fetchToFileAsync` 流式下载，单文件失败不中断，header 转圈处实时显示 `下载中 x/y` 进度
- **兼容下载**：旧实现（整包内存 + `fetchAsync`）
- **应急下载**：同步 FFI 直调（每项阻塞 UI）

### 缓存

`ProxyManager` 持有静态 `_imageCache`（`Map<String, Uint8List>`），`fetchAsync` 优先从缓存同步返回，避免重复 ECH 请求。  
`TwitterApi._metaCache` 缓存用户元数据，防止滚动重载。  
视频走文件缓存（spool + `.done` 标记），见上文"视频播放"。

## 构建

### CI/CD 流程

1. 推送至 main → 触发 workflow（`build_android` + `build_windows` 并行）
2. 安装 NDK r27 → 交叉编译 Go c-shared（wintools/ech-shared）→ `libechproxy.so` (Android) / `echproxy.dll` (Windows)
3. `flutter create` 脚手架 + 覆写 `lib/`、`assets/`、`pubspec.yaml`
4. 注入 `INTERNET` 权限、设置应用名"推图"
5. 签名：`key.properties` + `gradle.properties` 注入 `android.injected.signing.*`，密码通过 GitHub Secrets 管理
6. `flutter build apk --release --target-platform android-arm64` / `flutter build windows --release`
7. `create_release` 汇总两平台产物上传至 GitHub Releases（版本号按日期自动生成）

### API 端点

所有数据来自 `https://x.moonchan.xyz/api/twitter`：

| 端点 | 用途 |
| --- | --- |
| `searchUserList` | 搜索用户 |
| `getUserList` | 获取用户列表 |
| `getMetaData` | 获取用户元数据（头像、昵称等） |
| `getTags` | 获取标签列表 |
| `getEmojis` | 获取表情投票数据 |
| `getRanking` | 表情排行榜 |

## 注意事项

1. **版本号显示在标题栏** — 窗口/任务栏标题和 AppBar 均以 `BUILD_NUM`（例如 `v0.2.0+123`）为后缀，方便区分构建版本
2. **源码与平台文件分离** — `android/`、`ios/` 不提交，CI 动态生成
3. **Go 共享库** — `libechproxy.so` / `echproxy.dll` 由 CI 交叉编译，源码在 [Hana-ame/wintools](https://github.com/Hana-ame/wintools)，流式接口为 `ECHFetchBegin`/`ECHRead`/`ECHClose`
4. **仅 arm64** — `--target-platform android-arm64`
5. **JDK 17** — AGP 8.x 要求
6. **Flutter 3.44.3** — 版本锁定
7. **NDK r27**
8. **DoH** — 仅 `https://moonchan.xyz/doh`
9. **签名** — GitHub Secrets 跨构建一致；**7/25 起签名变更，老版本需卸载重装**
10. **不支持 iOS**

## 更新日志

- **v0.2.8**
  - 视频改为流式下载（ECHFetchBegin/ECHRead 分块写盘），大视频不再爆内存
  - 下载完成后 `video_player` 原地播放，按视频实际比例自适应（竖屏不被拉伸）
  - 视频封面抽帧（video_thumbnail）；批量下载 header 显示 `下载中 x/y` 进度
  - 播放控制栏 3 秒自动淡出 + 点击唤出，时间秒级实时刷新
  - 边下边播（系统播放器/ExoPlayer 播本地流）真机不可行，已移除
- **v0.2.3**
  - 修复收藏夹导出 URL 时剪贴板为空的问题。
  - 修复手机端无法通过系统播放器打开视频的问题（引入 `open_filex`）。
  - 配置 GitHub Actions 自动构建 APK 和 Windows EXE。
