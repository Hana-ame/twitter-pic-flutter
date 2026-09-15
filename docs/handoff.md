# Handoff — 自适应软解硬解 + 视频侧封装

> 交接点：v0.5.14 已发布（CI 全绿，APK/Windows zip 已出），所有代码已推到
> `feat/native-ech-poc`。用户要的"测什么"=这个版本。本文档供下个 agent 接力。

## 1. 这轮在做什么

用户要给视频播放做"自适应软解硬解"——硬解解不了/实例被占满时自动退软解。
做完 fork 后追问"是否所有播放中的视频都尽量硬解"+"检查效率问题"+"封装和组件都做好"。
本轮 = fork 接入 + 源码核实 + 效率修正 + 组件拆分 + 单测，v0.5.14 发版。

## 2. 关键决策与依据（全部 media3 1.9.2 源码核实，见对话）

- **fork 而非改本仓**：`video_player` 没暴露 `setEnableDecoderFallback`，
  上游 `DefaultRenderersFactory` 默认 false。已建外部 fork 仓库：
  `Hana-ame/video_player_android` tag `2.12.2-fallback.1`，基于上游 2.12.2，
  唯一改动 = 在 `TextureVideoPlayer`/`PlatformViewVideoPlayer` 里
  `new DefaultRenderersFactory(context).setEnableDecoderFallback(true)`。
- **"尽量硬解"成立**：framework 的 `MediaCodecList` 本身"最好的解码器在前"
  （`MediaCodecUtil.getDecoderInfosInternal` 注释），`MediaCodecVideoRenderer`
  再用 `getDecoderInfosSortedByFormatSupport` 把**真正支持该格式**的排最前；
  `enableDecoderFallback(true)` 只在"第一个 init 失败"时才顺延下一个。普通
  720p/1080p 永远走硬解；软解只在硬解声明解不了/初始化失败之后。
- **效率问题（核心结论）**：fork 开了软解回退后，media3 把"硬解实例被占满"
  的报错在播放器内部消化掉 → 旧 `DecodeBudget.onCodecFailure()` 的下调信号
  从此消失，报上来的 codec 错误 = 软硬解双双失败。继续"降档+重排×3"只是在
  墙内慢链路上重烧 moov 下载（纯浪费）。
  - **修法**（`lib/video/decoder_policy.dart`）：codec 类失败判 `failFast`
    （不重排、不动预算）；上限 1~6 → **1~3**（语义从"防撞硬解报错"变为
    "约束全软解的 CPU 负载"）；连击上调 3→4。
  - `DecodeBudget.onCodecFailure()` 保留但**当前无人调用**（关掉 fallback
    时的正确策略，测试仍覆盖，未删）。
- **Windows 端无此回退**（走 `video_player_win`/Media Foundation）。

## 3. 当前状态

- **已发布**：v0.5.14 — https://github.com/Hana-ame/twitter-pic-flutter/releases/tag/v0.5.14
- **CI 全绿**：flutter_test ✅（analyze 无 error，114 测试全过）/ build_android ✅
  / build_windows ✅ / create_release ✅
- **分支**：`feat/native-ech-poc`，tag `v0.5.14` 指向 commit `60ee677`
- **本地无 Flutter SDK**（用户明确禁止下载；所有验证走 CI，与 README 文化一致）
- **tag v0.5.14 曾 force-move 过两次**（先压 Uint8List import 修复，再压测试
  断言修复）—— release job 在 flutter_test 失败时被 skip，所以无脏 release。

## 4. 改了哪些文件（本轮，相对 v0.5.13）

### 新文件
| 文件 | 用途 |
| --- | --- |
| `lib/video/decoder_policy.dart` | 唯一知道 fork 语义的 Dart 层。`classify(e)` → `failFast`/`retryOnce`；上限参数 `kFallbackAwareCeiling=3`/`kSuccessStreakToRaise=4` |
| `lib/video/video_decoder_pool.dart` | `_PlayerPool` 拆出。只面向 `DecoderSlotUser` 接口；`note`/`saveBudget` 可注入 → 可单测。`shared` 懒建单例，起点读 `StorageService` 存档 |
| `lib/services/video_downloader.dart` | 卡片/全屏两份逐字复制的下载实现合一；文件名拼 `stableHash(url)` 防碰撞（同 `downloadToTempFile` 修法） |
| `lib/widgets/video/fullscreen_video.dart` | 全屏页拆出（原在 twitter_video.dart 里） |
| `lib/widgets/video/video_slider_with_buffer.dart` | 带缓冲显示的进度条（卡片/全屏共用） |
| `lib/utils/frame_luma.dart` | 黑帧判定 `isMostlyBlack()`（原 `_mostlyBlack` 内联在卡片里） |
| `test/decoder_policy_test.dart` | codec→failFast、网络→retryOnce、上限参数 |
| `test/video_decoder_pool_test.dart` | 分槽/可见优先/urgent 抢占/pump 重入/抓帧不可用兜底 |
| `test/frame_luma_test.dart` | 全黑/全亮/亮像素占比/质数步长不共振 |

### 改的文件
| 文件 | 改动 |
| --- | --- |
| `lib/widgets/twitter_video.dart` | 重写：`implements DecoderSlotUser`；catch 分支改用 `_pool.policy.classify(e)`；删 `_PlayerPool`/`_FullscreenVideo`/`_SliderWithBuffer`/`_mostlyBlack`/`_kMaxCodecRetries`/`_kCodecRetryDelay`/`_codecRetries`；修 `_capturePoster` 重复的第二次 `_becomePosterOnly()`；删空转的 `SingleTickerProviderStateMixin`；`Uint8List` 显式 `dart:typed_data`（下载拆走后不再随 `dart:io` 进来） |
| `lib/utils/video_failure.dart` | `humanize` codec 分支文案 + `isUnsupportedFormat` 注释更新（fork 后报上来的 = 软硬解都不行） |
| `lib/utils/decode_budget.dart` | 头注释加"现状：`onCodecFailure` 当前无人调用" |
| `lib/services/poster_service.dart` | 注释里的 `_PlayerPool` → `VideoDecoderPool` |
| `pubspec.yaml` | `video_player >=2.12.0 <2.15.0` + `dependency_overrides` 指向 fork（v0.5.13 轮已加） |
| `README.md` / `doc/troubleshooting.md` / `CHECKLIST.md` | 同步新语义、上限 1~3、组件化条目、更新日志 |

### 外部仓库（已推送）
- `Hana-ame/video_player_android` tag `2.12.2-fallback.1`（v0.5.13 轮建的）

## 5. 下一步（按优先级）

1. **真机验证**（用户该做的）：装 v0.5.14 APK，测之前报
   `NO_EXCEEDS_CAPABILITIES` 打不开的视频（如 4K60）现在能否播；日志看是否出现
   `c2.android.*` 软解。反馈卡顿程度（4K60 软解大概率卡）。
2. **若 4K60 软解卡到不可用**：考虑在 fork 里给 `DefaultRenderersFactory` 加
   一个自定义 `MediaCodecSelector`，对超大规格（`w*h*fps` 超阈值）**排除**
   软解候选 → 回到干净的永久失败（省 CPU）。需另起 fork tag + 新版。
3. **`onCodecFailure` 是否删除**：当前是"保留但无人调"的死分支。要么删干净，
   要么留作"关掉 fallback 时的正确策略"。倾向保留（测试覆盖着，删了反而少
   一道护栏）。
4. **`slotMounted` 接口成员未被池子使用**：可删或留作未来 dispose 竞态护栏。
5. **v0.5.14 的 tag force-move 历史**：若在意 release notes 的"自上一版"区间，
   检查 `git log v0.5.13..v0.5.14` 是否干净（应该只多这轮的 commit）。

## 6. 坑 / 教训（本轮踩的）

- **`Uint8List` 不随 `material` 进来**：以前靠 `dart:io` 顺带导出；下载逻辑拆到
  `video_downloader.dart` 后必须显式 `import 'dart:typed_data'`。CI analyze
  第一轮红在这个。
- **抢占发生在 `request()` 内部的 `pump()` 里**，不是 `nudge()`：非 urgent 抢占
  只要 victim 看不见且没在播就当场收位，`request()` 返回 true。测试第一轮断言
  写反（以为要先 `nudge`）。CI 第二轮红在这个。
- **`flutter_test` job 是 analyze + test 合一个 job**：analyze 失败时 test 根本
  不跑，看不到测试错误；analyze 过了才暴露测试断言问题。所以修了两轮。
- **本地禁下 Flutter SDK**（用户明确要求）；CI 是唯一裁判。README 本就写
  "CI 全程云端（本地无需 SDK）"。

## 7. 验证命令（CI 等价）

CI 的 `flutter_test` job = `flutter create` 脚手架 + `cp pubspec/lib/test` +
`flutter pub get` + `flutter analyze --no-fatal-infos --no-fatal-warnings` +
`flutter test --coverage`。本地无 SDK 时只能靠 `gh run watch`。
