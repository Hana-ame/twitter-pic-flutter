# 项目总检清单

## 主要目标
- [x] 浏览 Twitter 图片/视频（通过 ECH 代理绕过封锁）
- [x] 支持 Android 平台
- [x] 支持 Windows 平台
- [x] 自动 CI 构建 + Release

## ECH 代理（核心）
- [x] 使用 native wintools DLL/libechproxy 实现 ECH
- [x] 平台自适应：Windows → echproxy.dll / Linux → .so / macOS → .dylib
- [x] 支持自定义 DoH URL / Host / Bootstrap IP
- [x] ffi 2.2.0 兼容（`using`/`Arena`/`Utf8` 在 2.x 中仍可用）
- [ ] 迁移到纯 Dart ECH（等待 Flutter 内置支持）

## 代码结构
- [x] `lib/services/proxy_manager.dart` — ECH 代理 + image cache + 流式下载（不可删）
- [x] `lib/widgets/twitter_video.dart` — 视频流式下载 → 原地播放 + 封面（`video_player`/`video_thumbnail`）
- [x] `lib/widgets/twitter_image.dart` — 图片加载

## 视频功能现状（2026-08-14）
- [x] 流式下载（`ECHFetchBegin`/`ECHRead` 分块写盘，64KB buffer，不 OOM）
- [x] 下载完成原地播放（`video_player`），按实际宽高比自适应，竖屏不拉伸
- [x] 封面抽帧（`video_thumbnail` fork `Hana-ame/video_thumbnail` tag `v0.5.6-flutter44`，仅 Android/iOS）
- [x] 控制栏 3 秒自动淡出、点击唤出、秒级时间刷新
- [x] 批量下载 header 进度 `下载中 x/y`
- [x] spool 文件缓存 + `.done` 标记复用
- [ ] ~~边下边播~~ 真机不可行已移除（ExoPlayer chunked 不稳 / open_filex 系统播放器打不开）

## 构建状态（2026-08-14）
| 平台 | CI Job | 状态 |
|------|--------|------|
| Android | `build_android` | ✅ 通过 |
| Windows | `build_windows` | ✅ 通过 |
| Release | `create_release` | ✅ 通过 |

## 依赖管理
- `ffi: ^2.2.0` — `using`/`Arena`/`Utf8` 在 2.x 中仍可用，无需特殊处理
- `path_provider: ^2.1.5` — 本地路径获取（视频下载、缓存）
- `video_player: ^2.9.0` + `video_player_win: ^3.2.2` — 原地播放（federated 自动注册）
- `video_thumbnail` — git 依赖 fork（gradle 现代化，Java 实现不变）
- `open_filex` — 曾用于边下边播（系统播放器），已随功能移除

## 工作流注意事项
- `.github/workflows/build.yml` 不可删除，已适配 Windows x64 输出路径
- Go 版本: `stable`（CI 上取最新），用于编译 wintools/ech-shared
- Windows 构建需要 VS 环境（CI 自带）
- Android NDK r27 用于交叉编译 arm64 native 库
- manifest 注入已精简：仅 `INTERNET` 权限 + 应用名"推图"（cleartext/queries 注入随边下边播移除）
