// log_service.dart
// 日志落盘 + 异常退出检测 + 反馈包（dump）组装。
//
// 为什么需要它：闪退（进程级 abort / 原生崩溃）发生时会带走**所有内存态证据** ——
// Go 侧的日志环形缓冲随进程消失，Dart 侧连全局错误捕获都没有。结果就是
// 「有人汇报闪退，但我复现不了，也没有任何日志」。本文件负责三件事：
//
//   1. 把 Dart 错误与 Go 代理日志**持续追加到磁盘**（不是只留在内存里）；
//   2. 记一个「会话文件」，正常退出才标 cleanExit —— 没标上就说明上次没正常结束，
//      下次启动就能主动提示用户反馈（而不是等用户自己想起来）；
//   3. 把这些拼成一段可直接粘贴的反馈文本，附上反馈渠道。
//
// 注意：进程被 abort 时最后 ~2s 的 Go 日志可能来不及落盘（轮询间隔），这是
// 有意的取舍：不引入新的 FFI 导出符号（那要同步改 README / CHECKLIST / CI 的
// 符号清单），用轮询 + Go 侧 stderr tee 一起兜。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 一次「没有正常结束」的会话记录。
class Incident {
  final DateTime startedAt;
  final String buildNum;
  final DateTime detectedAt;

  const Incident({
    required this.startedAt,
    required this.buildNum,
    required this.detectedAt,
  });

  Map<String, dynamic> toJson() => {
        'startedAt': startedAt.toIso8601String(),
        'buildNum': buildNum,
        'detectedAt': detectedAt.toIso8601String(),
      };

  static Incident? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final s = raw['startedAt'];
    final d = raw['detectedAt'];
    if (s is! String || d is! String) return null;
    final started = DateTime.tryParse(s);
    final detected = DateTime.tryParse(d);
    if (started == null || detected == null) return null;
    final b = raw['buildNum'];
    return Incident(
      startedAt: started,
      buildNum: b is String ? b : 'unknown',
      detectedAt: detected,
    );
  }

  /// 描述里**不写「持续了多久」**：检测时刻是下次启动，两者之差不代表会话时长，
  /// 写成时长会误导（关了一夜再打开就变成「持续 9 小时」）。
  String get describe =>
      '版本 $buildNum · 上次会话开始于 ${_fmt(startedAt)}，'
      '于 ${_fmt(detectedAt)} 检测到它没有正常结束';
}

String _fmt(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String _stamp(DateTime t) =>
    '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

String _two(int v) => v.toString().padLeft(2, '0');

class LogService {
  LogService._();

  // ─── 反馈渠道（与网页端 HelpPage 保持一致）─────────────────────────────────
  /// 聊天群（chatto）：点开即可加入。
  static const String kGroupUrl = 'https://chatto.moonchan.xyz';

  /// 注册不了时的申请入口。
  static const String kGroupApplyUrl = 'https://chatto.810114.xyz';

  /// 群内房间名。
  static const String kGroupRoom = '推图';

  // ─── 容量上限（避免日志无限膨胀撑爆 app 目录）─────────────────────────────
  static const int maxLogBytes = 512 * 1024;
  static const int maxMemoryErrors = 100;
  static const int maxMemoryNotes = 60;
  static const int maxIncidents = 10;
  static const int maxAppendLinesPerPoll = 500;

  static bool _ready = false;
  static String _buildNum = 'dev';
  static Directory? _rootDir;

  /// 目录覆盖（测试用，绕开 path_provider）。
  static Directory? _dirOverride;

  /// 用户选择「不再提示」后持久化，避免每次启动都弹。
  static bool _promptSuppressed = false;

  static final List<String> _memoryErrors = <String>[];
  static final List<String> _memoryNotes = <String>[];
  static List<Incident> _incidents = <Incident>[];

  /// 写盘串行链：并发的 append / rename 交错会写坏文件（同 StorageService）。
  static Future<void> _chain = Future.value();

  // Go 日志增量追踪：只在环形缓冲被清空/裁剪时回退到全量。
  static int _goLogCount = 0;
  static String? _goLogTail;

  // ─── 生命周期 ─────────────────────────────────────────────────────────────

  static bool get isReady => _ready;

  static Future<void> ensureInitialized({String buildNum = 'dev'}) async {
    if (_ready) return;
    _buildNum = buildNum;
    try {
      final base = _dirOverride ?? await getApplicationSupportDirectory();
      _rootDir = Directory('${base.path}/logs');
      if (!await _rootDir!.exists()) {
        await _rootDir!.create(recursive: true);
      }
      _promptSuppressed = await _readSuppressed();
      _incidents = await _readIncidents();
      _ready = true;
    } catch (e) {
      // 拿不到目录（极端情况）：退化成纯内存，功能不致命。
      debugPrint('LogService init failed: $e');
      _rootDir = null;
      _ready = false;
    }
  }

  static File? _file(String name) {
    final dir = _rootDir;
    if (dir == null) return null;
    return File('${dir.path}/$name');
  }

  /// 开始一个新会话：写会话文件（cleanExit=false）。
  ///
  /// 同步写：会话文件只有几百字节，且必须在任何异步窗口之前落盘，
  /// 否则「启动后立刻闪退」这种情况检测不到。
  static void startSession() {
    final f = _file('session.json');
    if (f == null) return;
    final now = DateTime.now();
    try {
      f.writeAsStringSync(jsonEncode({
        'startedAt': now.toIso8601String(),
        'buildNum': _buildNum,
        'cleanExit': false,
      }));
    } catch (e) {
      debugPrint('LogService.startSession failed: $e');
    }
    // 在日志里打一条会话分隔线：反馈包里的日志是跨会话累积的，
    // 没有分隔线时根本分不清哪几行是崩掉那一次留下的。
    _append('app.log', ['', '=== 新会话 ${_fmt(now)} · v$_buildNum ===']);
  }

  /// 回到前台时把会话重新标成「进行中」。
  ///
  /// 必要性：`detached` 并不总意味着进程真的结束（Activity 销毁而进程还活着时
  /// 也会走到这里）。如果就此一直留着 `cleanExit=true`，之后再闪退就检测不到了。
  /// 所以每次 resumed 都把标记翻回 false —— 标记的语义是"最后一次已知状态是
  /// 没正常收尾"，而不是"本次进程已经退出"。
  static void markSessionActive() {
    _writeSession(cleanExit: false);
  }

  /// 正常退出（App 生命周期走到 detached）时打标。
  ///
  /// 同步写：这里已经在退出路径上，异步写可能来不及完成。
  static void markCleanExit() {
    _writeSession(cleanExit: true);
  }

  static void _writeSession({required bool cleanExit}) {
    final f = _file('session.json');
    if (f == null) return;
    try {
      if (!f.existsSync()) return;
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map) return;
      final map = raw.cast<String, dynamic>();
      map['cleanExit'] = cleanExit;
      // startedAt 保持首次写入的值：它表示"这个会话从什么时候开始"。
      f.writeAsStringSync(jsonEncode(map));
    } catch (e) {
      debugPrint('LogService._writeSession failed: $e');
    }
  }

  /// 启动时调用一次：判定上次是否**没有正常结束**。
  ///
  /// 判定依据只有「会话文件存在但没有 cleanExit 标记」。用户从任务管理器
  /// 强杀、或系统回收后台进程，也会落到这一类，所以 UI 文案必须写成
  /// 「上次运行没有正常结束」，而不是断定「闪退」。
  static Future<Incident?> takeUncleanExit() async {
    final f = _file('session.json');
    if (f == null) return null;
    try {
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return null;
      final map = raw.cast<String, dynamic>();
      if (map['cleanExit'] == true) return null;

      final s = map['startedAt'];
      final started = s is String ? DateTime.tryParse(s) : null;
      if (started == null) return null;

      final b = map['buildNum'];
      final incident = Incident(
        startedAt: started,
        buildNum: b is String ? b : 'unknown',
        detectedAt: DateTime.now(),
      );
      await _recordIncident(incident);
      return incident;
    } catch (e) {
      debugPrint('LogService.takeUncleanExit failed: $e');
      return null;
    }
  }

  static List<Incident> get incidents => List.unmodifiable(_incidents);
  static bool get promptSuppressed => _promptSuppressed;

  static Future<void> suppressPrompt() async {
    _promptSuppressed = true;
    final f = _file('prompt-suppressed');
    if (f == null) return;
    try {
      await f.writeAsString('1');
    } catch (_) {}
  }

  static Future<bool> _readSuppressed() async {
    final f = _file('prompt-suppressed');
    if (f == null) return false;
    try {
      return await f.exists();
    } catch (_) {
      return false;
    }
  }

  // ─── 记录 ─────────────────────────────────────────────────────────────────

  /// 记录一条 Dart 侧错误（全局 onError / runZonedGuarded 都接到这里）。
  static void recordError(String source, Object error, [StackTrace? stack]) {
    final line = '[${_fmt(DateTime.now())}] [$source] $error'
        '${stack == null ? '' : '\n$stack'}';
    _memoryErrors.add(line);
    if (_memoryErrors.length > maxMemoryErrors) {
      _memoryErrors.removeRange(0, _memoryErrors.length - maxMemoryErrors);
    }
    // 同时落到磁盘：只留内存的话，闪退时这条错误也没了。
    _append('app.log', ['### Dart 错误 [$source] $error']);
    if (stack != null) {
      _append('app.log', stack.toString().split('\n'));
    }
  }

  /// 记一条**非错误**的诊断信息（落盘 + 进反馈包）。
  ///
  /// 与 [recordError] 分开，是为了让反馈包里的段落名不撒谎：像"抓帧可用/不可用"
  /// 这类事实不是错误，但同样必须留痕 —— 否则真机上只能靠猜走了哪条分支。
  static void recordNote(String source, String message) {
    final line = '[${_fmt(DateTime.now())}] [$source] $message';
    _memoryNotes.add(line);
    if (_memoryNotes.length > maxMemoryNotes) {
      _memoryNotes.removeRange(0, _memoryNotes.length - maxMemoryNotes);
    }
    _append('app.log', ['### $source: $message']);
  }

  /// 把 Go 代理的日志环形缓冲增量追加到磁盘。
  ///
  /// 代理日志是一个固定长度（当前 500 行）的环形缓冲，所以不能只靠下标：
  /// 缓冲可能被裁剪（下标对不上）或被 StartProxy 清空。这里：
  ///   - 正常情况下从上次的条数往后追加；
  ///   - 对不上时先找上次的最后一行（取最后一次出现），只补它之后的部分；
  ///   - 完全找不到（被清空）就打个分隔标记，全量重写一遍。
  static Future<void> pollGoLogs(List<String> lines) {
    if (lines.isEmpty) return Future.value();
    final List<String> toAppend;
    if (_goLogTail != null &&
        lines.length > _goLogCount &&
        _goLogCount > 0 &&
        lines[_goLogCount - 1] == _goLogTail) {
      toAppend = lines.sublist(_goLogCount);
    } else {
      final tail = _goLogTail;
      var start = 0;
      if (tail != null) {
        final idx = lines.lastIndexOf(tail);
        if (idx >= 0) {
          start = idx + 1;
        } else {
          // 缓冲被清空（StartProxy）或已滚掉：标记后全量补。
          toAppend = <String>['--- Go 日志缓冲已轮转，以下是当前全部 ---', ...lines];
          _goLogCount = lines.length;
          _goLogTail = lines.last;
          return _append('app.log', _capLines(toAppend));
        }
      }
      toAppend = lines.sublist(start);
    }
    _goLogCount = lines.length;
    _goLogTail = lines.last;
    if (toAppend.isEmpty) return Future.value();
    return _append('app.log', _capLines(toAppend));
  }

  static List<String> _capLines(List<String> lines) =>
      lines.length <= maxAppendLinesPerPoll
          ? lines
          : lines.sublist(lines.length - maxAppendLinesPerPoll);

  /// 实际的文件写入（追加 + 必要时轮转）。**不碰 [_chain]。**
  ///
  /// 单独拆出来是因为 [_append] 会把任务挂到 [_chain] 上；已经**在链上**的
  /// 代码（比如 [clearLogs]）不能再调 _append —— 那会重新赋值
  /// `_chain = _chain.then(...)`，变成"链里的回调等链自己完成"，直接死锁
  /// （CI 实测：两个用例都 30s 超时）。链内的代码调本方法。
  static Future<void> _writeFile(String name, List<String> lines) async {
    final f = _file(name);
    if (f == null || lines.isEmpty) return;
    await f.writeAsString('${lines.join('\n')}\n', mode: FileMode.append);
    final size = await f.length();
    if (size > maxLogBytes) {
      final old = _file('$name.1');
      if (old != null) {
        if (await old.exists()) await old.delete();
        await f.rename(old.path);
      }
    }
  }

  /// 追加若干行到日志文件，必要时轮转。
  static Future<void> _append(String name, List<String> lines) {
    if (_file(name) == null || lines.isEmpty) return Future.value();
    _chain = _chain.then((_) async {
      try {
        await _writeFile(name, lines);
      } catch (e) {
        debugPrint('LogService._append failed: $e');
      }
    });
    return _chain;
  }

  /// 等待挂起的写入完成（退出前 / 测试里用）。
  static Future<void> flush() => _chain;

  /// 清空日志：磁盘日志文件 + 内存里待反馈的日志内容。
  ///
  /// **有意不清**的东西：
  /// - `incidents.json` / [_incidents]：异常结束记录，与"日志"无关，而且清空
  ///   它会让反馈包丢掉最近一次崩溃的上下文。
  /// - `session.json`：崩溃检测的标记位。删了它，[takeUncleanExit] 下次启动
  ///   就永远判不出"未正常结束"了 —— 正好毁掉这个功能存在的理由。
  ///
  /// **Go 侧内存环形缓冲清不掉**：没有对应的 FFI 导出（[kMaxGoLogLines] 行的
  /// ring 只在 Go 侧 StartProxy 里被清空）。所以下一次 [pollGoLogs]
  /// 会把当前 ring 重新写回一个新的 app.log —— 这是预期行为：「查看日志」
  /// 页面显示的本来就是这个 ring，清了 app.log 它还在，下一次轮询再补回来。
  ///
  /// 游标必须**在删文件之前**同步重置：残留的 [_goLogTail] 会让下一次轮询
  /// 走"整段重写"分支，把旧内容重新灌回来。这两行之间没有 await，所以不会
  /// 被正在跑的轮询插队。
  ///
  /// 文件操作挂到 [_chain] 末尾，排在此前所有 append 之后。**链内必须用
  /// [_writeFile]，不能用 [_append]** —— _append 会重新赋值 `_chain`，而
  /// 我们正在等 _chain 完成，会死锁（CI 实测两个用例 30s 超时）。
  static Future<void> clearLogs() async {
    _goLogTail = null;
    _goLogCount = 0;
    // 原地 clear 而不是重新赋值：这两个是 static final，而且 buildDump 可能
    // 正拿着引用在组包，换对象会让它读到旧的（已清空前的）列表。
    _memoryErrors.clear();
    _memoryNotes.clear();
    _chain = _chain.then((_) async {
      try {
        for (final name in const ['app.log', 'app.log.1']) {
          final f = _file(name);
          if (f == null) continue;
          if (await f.exists()) await f.delete();
        }
        // 留一条分隔线，方便在反馈包里看出"清除"发生过（同会话分隔线的约定）。
        // 刚删完两个文件，新 app.log 只有这一行，轮转不会触发。
        await _writeFile('app.log', [
          '',
          '=== 日志已清除 ${_fmt(DateTime.now())} ===',
        ]);
      } catch (e) {
        debugPrint('LogService.clearLogs failed: $e');
      }
    });
    return _chain;
  }

  /// 读日志文件末尾若干行（跨轮转文件一起读）。
  static Future<List<String>> logTail({int maxLines = 400}) async {
    final out = <String>[];
    for (final name in <String>['app.log.1', 'app.log']) {
      final f = _file(name);
      if (f == null) continue;
      try {
        if (!await f.exists()) continue;
        final lines = await f.readAsLines();
        out.addAll(lines);
      } catch (_) {}
    }
    if (out.length <= maxLines) return out;
    return out.sublist(out.length - maxLines);
  }

  static Future<void> _recordIncident(Incident incident) async {
    _incidents = <Incident>[incident, ..._incidents];
    if (_incidents.length > maxIncidents) {
      _incidents = _incidents.sublist(0, maxIncidents);
    }
    final f = _file('incidents.json');
    if (f == null) return;
    try {
      await f.writeAsString(
        jsonEncode(_incidents.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('LogService._recordIncident failed: $e');
    }
  }

  static Future<List<Incident>> _readIncidents() async {
    final f = _file('incidents.json');
    if (f == null) return <Incident>[];
    try {
      if (!await f.exists()) return <Incident>[];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return <Incident>[];
      return raw
          .map(Incident.fromJson)
          .whereType<Incident>()
          .toList(growable: false);
    } catch (_) {
      return <Incident>[];
    }
  }

  // ─── 反馈包 ───────────────────────────────────────────────────────────────

  /// 组装可直接粘贴的反馈文本。
  ///
  /// [extra] 由调用方补充运行时上下文（代理状态等）—— 本文件刻意不依赖
  /// ProxyManager，保持可在无插件的纯 Dart 测试里跑。
  static Future<String> buildDump({
    Map<String, String> extra = const <String, String>{},
    int maxLogLines = 400,
  }) async {
    final now = DateTime.now();
    final buf = StringBuffer();
    buf.writeln('=== Twitter Pic 反馈日志 ===');
    buf.writeln('版本: $_buildNum');
    buf.writeln('平台: ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}');
    buf.writeln('生成时间: ${_fmt(now)}');
    extra.forEach((k, v) => buf.writeln('$k: $v'));
    if (_incidents.isNotEmpty) {
      buf.writeln('上次异常结束: ${_incidents.first.describe}');
    }
    buf.writeln('');

    if (_memoryErrors.isNotEmpty) {
      buf.writeln('--- 本次运行 Dart 错误（最近 ${_memoryErrors.length} 条）---');
      buf.writeln(_memoryErrors.join('\n\n'));
      buf.writeln('');
    }

    if (_memoryNotes.isNotEmpty) {
      buf.writeln('--- 本次运行诊断（非错误）---');
      buf.writeln(_memoryNotes.join('\n'));
      buf.writeln('');
    }

    final tail = await logTail(maxLines: maxLogLines);
    buf.writeln('--- 日志文件（最近 ${tail.length} 行）---');
    if (tail.isEmpty) {
      buf.writeln('(空：本次运行还没写入日志)');
    } else {
      buf.writeln(tail.join('\n'));
    }
    buf.writeln('');

    buf.writeln('--- 反馈方式 ---');
    buf.writeln('请把上面这段内容发到聊天群（加群即可）：');
    buf.writeln('  $kGroupUrl');
    buf.writeln('注册不了可在 $kGroupApplyUrl 提交申请');
    buf.writeln('群内房间：$kGroupRoom');
    return buf.toString();
  }

  /// 把反馈包写成文件（在 app 支持目录的 logs/ 下），返回文件。
  static Future<File?> writeDump({
    Map<String, String> extra = const <String, String>{},
    String prefix = 'dump',
  }) async {
    final text = await buildDump(extra: extra);
    final f = _file('$prefix-${_stamp(DateTime.now())}.txt');
    if (f == null) return null;
    try {
      await f.writeAsString(text);
      return f;
    } catch (e) {
      debugPrint('LogService.writeDump failed: $e');
      return null;
    }
  }

  /// 供设置页展示：日志目录（用户找不到文件时用得上）。
  static String? get logDirectoryPath => _rootDir?.path;

  // ─── 测试钩子 ─────────────────────────────────────────────────────────────

  @visibleForTesting
  static void resetForTests() {
    _ready = false;
    _buildNum = 'dev';
    _rootDir = null;
    _dirOverride = null;
    _promptSuppressed = false;
    _memoryErrors.clear();
    _memoryNotes.clear();
    _incidents = <Incident>[];
    _chain = Future.value();
    _goLogCount = 0;
    _goLogTail = null;
  }

  /// 测试用：指定日志目录，等价于 path_provider 返回该目录。
  @visibleForTesting
  static Future<void> debugUseDirectory(Directory dir) async {
    _dirOverride = dir;
    await ensureInitialized(buildNum: 'test');
  }
}
