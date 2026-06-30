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
- [x] `lib/services/proxy_manager.dart` — ECH 代理 + image cache（不可删）
- [x] `lib/widgets/twitter_video.dart` — 视频下载与播放（`url_launcher`）
- [x] `lib/widgets/twitter_image.dart` — 图片加载

## 构建状态（2026-06-30）
| 平台 | CI Job | 状态 |
|------|--------|------|
| Android | `build_android` | ✅ 通过 |
| Windows | `build_windows` | ✅ 通过 |
| Release | `create_release` | ✅ 通过 |

## 依赖管理
- `ffi: ^2.2.0` — `using`/`Arena`/`Utf8` 在 2.x 中仍可用，无需特殊处理
- `path_provider: ^2.1.5` — 本地路径获取（视频下载、缓存）

## 工作流注意事项
- `.github/workflows/build.yml` 不可删除，已适配 Windows x64 输出路径
- Go 版本: `1.26`，用于编译 wintools/ech-shared
- Windows 构建需要 VS2025 环境（CI 自带）
- Android NDK r27 用于交叉编译 arm64 native 库
