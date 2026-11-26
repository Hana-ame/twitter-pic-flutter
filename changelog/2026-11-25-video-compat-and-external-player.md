# 2026-11-25 视频兼容模式、外部播放器模式与 HTTP 404/403 诊断修复

## 变更摘要

1. **外部播放器模式（`StorageService.isExternalVideoPlayer` + `VideoCompatChannel.openExternalPlayer`）**
   - 设置页「视频播放兼容」区新增独立开关「外部播放器模式」（默认关闭），视频卡片长按菜单新增「用外部播放器打开」快捷项。
   - 开启后点击视频封面或卡片不再初始化内置 ExoPlayer，而是直接通过本机 ECH 代理 URL（`http://127.0.0.1:<port>/...`，默认 `8443`）拉起外部播放器（Android 走 `Intent.ACTION_VIEW` + `video/*`，Windows 走系统默认关联程序）。
   - 配套 `Hana-ame/video_player_android`（`2.12.2-fallback.2`）在 `VideoPlayerPlugin` 轻量 `MethodChannel` 新增 `openExternalVideo`，零新增 Dart 依赖、不改 Pigeon 协议。

2. **HTTP 404 / 403 / 410 错误解包与 `failFast` 处理**
   - 修复 Release 包 R8 混淆后 `ExoPlayerEventListener.onPlayerError` 只报 `v.j: Source error`、丢失底层 `HttpDataSource.InvalidResponseCodeException.responseCode` 的问题。
   - `video_player_android` 现输出 `[ERROR_CODE_*, HTTP <status>]`，`VideoFailure.httpStatusCode` / `isHttpGoneOrForbidden` 与 `DecoderPolicy.classify` 将 403/404/410 判为 `failFast`（不再自动重试，并给出明确中文提示），5xx 仍保留一次重试。

3. **软解卡顿警示同步至 `AGENTS.md` 与 `README.md`**
   - 明确记录实机结论：**软解（`c2.android.*`）在高码率/高帧率视频上会卡顿且部分视频无法播放**（不阻塞代码修复，但每次涉及软解时必须提示，避免遗忘）。
   - 同步更新设置页提示文案，优先引导使用硬解路径（原生视图 / 外部播放器）。

4. **单测与门禁验证**
   - `test/decoder_policy_test.dart` 新增 HTTP 404/403 `failFast` 与 502 `retryOnce` 用例。
   - `test/video_compat_mode_test.dart` 新增外部播放器开关持久化与 `clearAll` 复位用例。

5. **第三条兼容线：关闭 Impeller（`EnableImpeller=false`）由「未实装」转为已实装**
   - `.github/workflows/build.yml` 的 `build_android` 新增 `Build APK with Impeller disabled`：在 `AndroidManifest.xml` 的 `<application>` 下注入
     `<meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false" />` 后重新构建，产出 `app-release-noimpeller.apk`。
   - 两个 APK 放在**同一个** `apk` artifact；`create_release` 一并下载、一并挂出，`SHA256SUMS.txt` 从 2 行变 3 行（断言同步更新）。
   - **硬闸门**：两个 APK 的 sha256 必须不同，否则判定「meta-data 注入静默失败」并 fail —— 防的是"号称关了 Impeller、实际没关，而 CI 全绿"。
   - 意义：斜切/绿纹的纹理采样 bug 只存在于 Impeller 的 `ImageReaderSurfaceProducer` 路径上；关掉 Impeller 退回 Skia 后**硬解照旧**，不掉帧也不软解。代价是全局动效略逊，所以只做可选包，不改默认。

6. **设置页角标（`VideoCompatModeProps.badge` / `cpuHeavy`）**
   - `platformView` 标「推荐」，三个软解档标「软解·可能掉帧」，按实测效果排序而非枚举顺序。
   - `cpuHeavy` 为真时，错误卡片额外点明「HTTP 类失败与解码方式无关，别为此留在软解档」。

