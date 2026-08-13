// 本地流式代理服务：把 ECH 流式下载中的 spool 文件暴露成 127.0.0.1 HTTP 流，
// 供 video_player 边下边播。只监听 loopback，不对局域网开放。
//
// 为什么需要它：ExoPlayer 等播放器只能播 HTTP URL，无法直接读"正在增长的文件"。
// Twitter mp4 是 faststart（moov 在文件头，已用真实视频验证），
// 播放器顺序拉取前几 KB 即可开播，其余数据边下边补。
//
// 设计决策：
// - 无 Range 请求（顺序播放）：chunked 实时流，读已下载部分，随下载增长；
// - Range 请求（seek）：等待所需字节全部就绪后，用确定的 Content-Length 回 206。
//   因为 206 响应需要精确长度而下载中长度未知；顺序播放器不发 Range，
//   只有 seek 才发，等待可接受（seek 到尾部约等于等下载完成）。
import 'dart:io';
import 'dart:typed_data';

class StreamingServer {
  StreamingServer._();
  static final StreamingServer instance = StreamingServer._();

  HttpServer? _server;
  int _port = 0;
  int _nextToken = 1;
  final Map<String, _Task> _tasks = {};

  static const int _bufSize = 64 * 1024;

  Future<String> register(String url, String spoolPath) async {
    if (_server == null) {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = s;
      _port = s.port;
      s.listen(_handle, onError: (_) {});
    }
    final token = (_nextToken++).toString();
    _tasks[token] = _Task(url, spoolPath);
    return token;
  }

  String urlFor(String token) => 'http://127.0.0.1:$_port/v/$token';

  void markDone(String token, int total) {
    final t = _tasks[token];
    if (t == null) return;
    t.done = true;
    t.total = total;
  }

  void markFailed(String token, Object error) {
    _tasks[token]?.failed = '$error';
  }

  void unregister(String token) {
    _tasks.remove(token);
  }

  void _handle(HttpRequest req) {
    try {
      final seg = req.uri.pathSegments;
      final task = (seg.length == 2 && seg[0] == 'v') ? _tasks[seg[1]] : null;
      if (task == null) {
        req.response.statusCode = HttpStatus.notFound;
        req.response.close();
        return;
      }
      _serve(req, task).catchError((_) {});
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serve(HttpRequest req, _Task task) async {
    final file = File(task.path);
    if (!file.existsSync()) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final range = _parseRange(req.headers.value(HttpHeaders.rangeHeader));
    if (range != null) {
      // seek 请求：等待所需范围就绪再回确定的 206。
      final endReady = await (range.endIsOpen
          ? _waitUntilDone(task, file)
          : _waitUntil(task, file, range.end + 1));
      if (endReady < 0 || endReady <= range.start) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await req.response.close();
        return;
      }
      final len = endReady - range.start;
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers
        ..set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${endReady - 1}/$endReady',
        )
        ..contentLength = len;
      await _pump(req.response, file, range.start, len, task);
      return;
    }
    // 顺序播放：下载已完成则给确定长度，否则 chunked 跟随增长。
    if (task.done && task.total != null) {
      req.response.headers.contentLength = task.total;
      await _pump(req.response, file, 0, task.total, task);
      return;
    }
    await _pump(req.response, file, 0, null, task);
  }

  // 从文件流式输出。limit 为 null 表示跟随下载增长直到完成/失败；
  // 否则输出恰好 limit 字节后关闭。文件被删（spool 清理）时静默中断。
  Future<void> _pump(
      HttpResponse resp, File file, int start, int? limit, _Task task) async {
    RandomAccessFile? raf;
    try {
      raf = file.openSync(mode: FileMode.read);
      raf.setPositionSync(start);
      var pos = start;
      final buf = Uint8List(_bufSize);
      while (true) {
        if (limit != null && pos - start >= limit) break;
        final size = raf.lengthSync();
        if (pos < size) {
          // clamp 返回 num，readIntoSync 要 int，用三元避免编译错误。
          final want = size - pos;
          final n = raf.readIntoSync(buf, 0, want < buf.length ? want : buf.length);
          if (n == 0) break;
          resp.add(Uint8List.sublistView(buf, 0, n));
          await resp.flush();
          pos += n;
        } else if (task.failed != null || task.done) {
          break; // 下载失败 → EOF 让播放器感知停止；完成 → 正常 EOF
        } else {
          await Future.delayed(const Duration(milliseconds: 80));
        }
      }
    } catch (_) {
      // 客户端断开 / spool 被清理：静默结束。
    } finally {
      raf?.closeSync();
      try {
        await resp.close();
      } catch (_) {}
    }
  }

  // 等待文件增长到 >= needBytes 字节，返回当前文件大小；失败返回 -1。
  // 下载已完成则直接返回实际大小（可能小于 needBytes，由调用方判 416），
  // 避免"文件已停止增长但长度不够"时空转到 30 分钟超时。
  Future<int> _waitUntil(_Task task, File file, int needBytes) async {
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (task.failed != null) return -1;
      final size = _safeLength(file);
      if (task.done) return size;
      if (size >= needBytes) return size;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return -1;
  }

  // 等待下载完成，返回总字节数；失败返回 -1。
  Future<int> _waitUntilDone(_Task task, File file) async {
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (task.failed != null) return -1;
      if (task.done && task.total != null) return task.total!;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return -1;
  }

  static int _safeLength(File file) {
    try {
      return file.lengthSync();
    } catch (_) {
      return -1;
    }
  }
}

class _Task {
  _Task(this.url, this.path);
  final String url;
  final String path;
  bool done = false;
  int? total;
  String? failed;
}

class _Range {
  _Range(this.start, this.end, this.endIsOpen);
  final int start;
  final int end;
  final bool endIsOpen;
}

_Range? _parseRange(String? header) {
  if (header == null) return null;
  final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
  if (m == null) return null;
  final start = int.parse(m.group(1)!);
  final endRaw = m.group(2);
  if (endRaw == null || endRaw.isEmpty) return _Range(start, 0, true);
  return _Range(start, int.parse(endRaw), false);
}
