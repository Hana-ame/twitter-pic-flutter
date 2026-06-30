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
| 构建 | GitHub Actions: NDK r27 + Go 1.26 + Flutter 3.44.3 |
| 发布 | GitHub Releases (APK 自动上传) |

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
│   ├── proxy_manager.dart        # FFI 加载 libechproxy.so + init/async fetch/缓存
│   └── storage_service.dart      # localStorage 封装 (收藏/屏蔽/标签规则)
├── widgets/
│   ├── twitter_image.dart        # 图片组件，ECH 异步加载
│   ├── twitter_video.dart        # 视频组件：ECH 下载 → 临时文件 → 系统播放器
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
│  Flutter App ──Isolate.run + FFI── Go  │
│  (fetchAsync)    ECHFetch(url)     ECH │
│                    ← raw bytes    Client│
│                     Image.memory       │
│           或 temp file + system player │
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
   视频：返回 mp4 字节 → 写入临时文件 → `am start` 调系统播放器

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

完整的 mp4 通过 `fetchAsync` 下载（ECH），写入 app 临时目录，通过 `Process.run` 调系统播放器，平台自适应：

| 平台 | 命令 |
|------|------|
| Android | `am start …` |
| Windows | `cmd /c start "" <path>` |
| macOS   | `open <path>` |
| Linux   | `xdg-open <path>` |

### 缓存

`ProxyManager` 持有静态 `_imageCache`（`Map<String, Uint8List>`），`fetchAsync` 优先从缓存同步返回，避免重复 ECH 请求。  
`_metaCache` 缓存用户元数据，防止滚动重载。

## 构建

### CI/CD 流程

1. 推送至 main → 触发 workflow
2. 安装 NDK r27 → 交叉编译 Go c-shared → `libechproxy.so` (~6MB)
3. `flutter create` 脚手架 + 覆写 `lib/`、`assets/`、`pubspec.yaml`
4. 注入 `INTERNET` 权限
5. 签名：`gradle.properties` 注入 `android.injected.signing.*`，密码通过 GitHub Secrets 管理
6. `flutter build apk --release --target-platform android-arm64`
7. 上传至 GitHub Releases

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
3. **Go 共享库** — `libechproxy.so` (~6.4MB) 由 CI 交叉编译，源码在 [Hana-ame/wintools](https://github.com/Hana-ame/wintools)
4. **仅 arm64** — `--target-platform android-arm64`
5. **JDK 17** — AGP 8.x 要求
6. **Flutter 3.44.3** — 版本锁定
7. **NDK r27**
8. **DoH** — 仅 `https://moonchan.xyz/doh`
9. **签名** — `gradle.properties` + GitHub Secrets，跨构建一致
10. **不支持 iOS**