// poster_service.dart
// 视频封面（静帧）缓存：内存 + 磁盘二级。
//
// 为什么需要它：Android 的**硬件**解码器实例只有 2~4 个（720p60 High profile 往往
// 只吃得下 2 个），而时间线上每一张视频卡片都想显示一张静帧。靠"每张卡片都开一个
// 播放器"必然撞上限（见 _PlayerPool 与 doc/troubleshooting.md 案例 14）。
//
// 做法：卡片持有播放器时**抓一次当前帧**当封面（`RepaintBoundary.toImage()`，不额外
// 占解码器），存到这里（内存 + 磁盘）。之后这张卡片再被池子回收，就能用缓存封面
// 继续显示静帧 —— 于是"静帧数量"不再受解码器数量限制，而解码器始终只服务于正在
// 操作的那一两路。
//
// 注意封面是**按视频 URL**缓存的，与代理端口无关：同一视频 URL 在代理重启后
// 端口会变，但内容一样，所以 key 用原始 URL（不含端口/路径改写）。
//
// 抽帧没有用 video_thumbnail（MediaMetadataRetriever）：它自己也要占一个解码器，
// 会在"播放器池已经占满"时把并发解码数顶到 3 —— 正是要避免的事。抓屏不占解码器，
// 代价是**抓不到 Texture 时会是整片黑**，所以那边有黑帧检查（见 twitter_video.dart）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/stable_hash.dart';

class PosterService {
  PosterService._();

  /// 内存缓存条数上限。封面是按 480px 级 PNG 存的，单张几十 KB，
  /// 60 条也就是几 MB —— 比让用户重新抽帧划算。
  static const int maxMemoryEntries = 60;

  /// 磁盘目录名（在应用支持目录下）。
  static const String dirName = 'posters';

  static final Map<String, Uint8List> _memory = <String, Uint8List>{};

  /// 插入顺序即 LRU 顺序（Dart 的 Map 保持插入顺序）。
  static final List<String> _memoryOrder = <String>[];

  static Directory? _rootDir;
  static Directory? _dirOverride;
  static bool _ready = false;

  static bool get isReady => _ready;

  static String? get directoryPath => _rootDir?.path;

  static Future<void> ensureInitialized() async {
    if (_ready) return;
    try {
      final base = _dirOverride ?? await getApplicationSupportDirectory();
      _rootDir = Directory('${base.path}/$dirName');
      if (!await _rootDir!.exists()) {
        await _rootDir!.create(recursive: true);
      }
      _ready = true;
    } catch (e) {
      debugPrint('PosterService init failed: $e');
      _rootDir = null;
      _ready = false;
    }
  }

  static String keyFor(String videoUrl) => stableHash(videoUrl);

  /// 封面是 PNG（抓屏用 `ImageByteFormat.png` 编码）—— 扩展名别写成 .jpg，
  /// 否则以后有人按 JPEG 去解析会莫名其妙。
  static const String fileExtension = 'png';

  static File? _file(String videoUrl) {
    final dir = _rootDir;
    if (dir == null) return null;
    return File('${dir.path}/${keyFor(videoUrl)}.$fileExtension');
  }

  /// 只查内存（不碰磁盘）。
  static Uint8List? memory(String videoUrl) => _memory[videoUrl];

  /// 先内存、后磁盘。命中磁盘会回填内存。
  static Future<Uint8List?> load(String videoUrl) async {
    final hit = _memory[videoUrl];
    if (hit != null) {
      _touchMemory(videoUrl);
      return hit;
    }
    final f = _file(videoUrl);
    if (f == null) return null;
    try {
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return null;
      _putMemory(videoUrl, bytes);
      return bytes;
    } catch (e) {
      debugPrint('PosterService.load failed: $e');
      return null;
    }
  }

  /// 写入内存 + 磁盘。
  ///
  /// 磁盘失败不影响内存命中（本次会话里照样有封面可用）。
  static Future<void> put(String videoUrl, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    _putMemory(videoUrl, bytes);
    final f = _file(videoUrl);
    if (f == null) return;
    try {
      await f.writeAsBytes(bytes, flush: true);
    } catch (e) {
      debugPrint('PosterService.put failed: $e');
    }
  }

  static void _putMemory(String videoUrl, Uint8List bytes) {
    _memory[videoUrl] = bytes;
    _touchMemory(videoUrl);
    while (_memoryOrder.length > maxMemoryEntries) {
      final evicted = _memoryOrder.removeAt(0);
      _memory.remove(evicted);
    }
  }

  static void _touchMemory(String videoUrl) {
    _memoryOrder.remove(videoUrl);
    _memoryOrder.add(videoUrl);
  }

  /// 清空磁盘封面（设置页「清除数据」用）。
  static Future<void> clearAll() async {
    _memory.clear();
    _memoryOrder.clear();
    final dir = _rootDir;
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
    } catch (e) {
      debugPrint('PosterService.clearAll failed: $e');
    }
  }

  // ─── 测试钩子 ─────────────────────────────────────────────────────────────

  @visibleForTesting
  static void resetForTests() {
    _ready = false;
    _rootDir = null;
    _dirOverride = null;
    _memory.clear();
    _memoryOrder.clear();
  }

  /// 测试用：指定缓存根目录，等价于 path_provider 返回该目录。
  @visibleForTesting
  static Future<void> debugUseDirectory(Directory dir) async {
    _dirOverride = dir;
    await ensureInitialized();
  }
}
