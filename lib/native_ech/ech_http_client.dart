// ECH 通道上的 HTTP/1.1 客户端（PoC，M3 前置）。
//
// 只做本项目需要的子集：GET、Content-Length 与 chunked 响应体、
// 流式回调消费（视频边下边写盘）。不追全量 RFC。
//
// 解析相关（HttpResponseHead / ChunkedDecoder / buildRequest）是纯 Dart，
// 已单测；网络流程依赖 [EchSocket]，随 M2 在 CI 冒烟。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// HTTP/1.1 响应头。`tryParse` 在缓冲不足时返回 null（继续等网络）。
class HttpResponseHead {
  final int statusCode;
  final String reasonPhrase;
  final Map<String, String> headers; // key 小写
  final int headerByteLength; // 头部总长（含结尾 CRLFCRLF）

  const HttpResponseHead(
      this.statusCode, this.reasonPhrase, this.headers, this.headerByteLength);

  int? get contentLength {
    final v = headers['content-length'];
    if (v == null) return null;
    return int.tryParse(v.trim());
  }

  bool get isChunked =>
      (headers['transfer-encoding'] ?? '').toLowerCase().contains('chunked');

  static const _sep = [13, 10, 13, 10]; // \r\n\r\n

  static HttpResponseHead? tryParse(List<int> buf) {
    final end = _indexOf(buf, _sep, 0);
    if (end < 0) return null;
    final headText = latin1.decode(buf.sublist(0, end));
    final lines = headText.split('\r\n');
    if (lines.isEmpty) return null;
    final m = RegExp(r'^HTTP/1\.[01] (\d{3})(?: (.*))?$')
        .firstMatch(lines.first);
    if (m == null) return null;
    final headers = <String, String>{};
    for (var i = 1; i < lines.length; i++) {
      final c = lines[i].indexOf(':');
      if (c <= 0) continue;
      headers[lines[i].substring(0, c).trim().toLowerCase()] =
          lines[i].substring(c + 1).trim();
    }
    return HttpResponseHead(
        int.parse(m.group(1)!), m.group(2) ?? '', headers, end + _sep.length);
  }

  static int _indexOf(List<int> hay, List<int> needle, int from) {
    for (var i = from; i <= hay.length - needle.length; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }
}

/// 增量 chunked 解码：push 喂原始字节，解码出的实体经 [emit] 吐出。
class ChunkedDecoder {
  final void Function(Uint8List chunk) emit;

  /// -1：正在等一行 chunk-size；>0：正在收数据段（剩余字节数，不含尾 CRLF）。
  int _remaining = -1;
  final _buf = <int>[];
  bool _done = false;

  ChunkedDecoder(this.emit);

  bool get done => _done;

  void push(List<int> data) {
    if (_done) return;
    _buf.addAll(data);
    while (!_done) {
      if (_remaining < 0) {
        // 状态 A：读一行 chunk-size（可带 ";ext" 扩展）
        final nl = _findCrLf();
        if (nl < 0) return; // 行未齐
        final line = latin1.decode(_buf.sublist(0, nl));
        final hex =
            line.contains(';') ? line.substring(0, line.indexOf(';')) : line;
        final size = int.tryParse(hex.trim(), radix: 16);
        if (size == null || size < 0) {
          throw FormatException('bad chunk size line: "$line"');
        }
        _buf.removeRange(0, nl + 2);
        if (size == 0) {
          _done = true; // 终止块；trailer 忽略
          _buf.clear();
          return;
        }
        _remaining = size;
      }
      // 状态 B：收数据段 + 结尾 CRLF
      if (_buf.length < _remaining + 2) return; // 未齐
      emit(Uint8List.fromList(_buf.sublist(0, _remaining)));
      if (_buf[_remaining] != 13 || _buf[_remaining + 1] != 10) {
        throw FormatException('missing CRLF after chunk data');
      }
      _buf.removeRange(0, _remaining + 2);
      _remaining = -1;
    }
  }

  int _findCrLf() {
    for (var i = 0; i + 1 < _buf.length; i++) {
      if (_buf[i] == 13 && _buf[i + 1] == 10) return i;
    }
    return -1;
  }
}

/// 基于 [EchSocket] 的 GET；响应体经 [onChunk] 流式吐出。
///
/// ⚠️ 依赖 M2 的 EchSocket（证书校验接通前不可用），整体仍是骨架。
class EchHttpClient {
  final String Function() caBundlePath;

  EchHttpClient({required this.caBundlePath});

  Future<HttpResponseHead> get(
    String host,
    String path, {
    required void Function(Uint8List chunk) onChunk,
    Map<String, String>? extraHeaders,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    // M3 接线顺序：
    //   final ech = await HttpsRrEchFetcher().fetchEchConfigList(host);
    //   if (ech == null) throw ...;            // 回退 Go FFI 通道
    //   final s = await EchSocket.connect(host,
    //       echConfigList: ech, caBundlePath: caBundlePath());
    //   s.add(EchHttpClient.buildRequest(host, path, extraHeaders: extraHeaders));
    //   订阅 s.plaintext → tryParse 头 → 按 CL/chunked 路由体数据。
    throw UnimplementedError('M3: wire up with EchSocket once M2 lands in CI');
  }

  /// 生成请求字节（独立出来便于单测）。
  static Uint8List buildRequest(String host, String path,
      {Map<String, String>? extraHeaders}) {
    final sb = StringBuffer('GET $path HTTP/1.1\r\n');
    sb.write('Host: $host\r\n');
    sb.write('User-Agent: twitter-pic-flutter/ech-poc\r\n');
    sb.write('Accept: */*\r\n');
    extraHeaders?.forEach((k, v) => sb.write('$k: $v\r\n'));
    sb.write('\r\n');
    return Uint8List.fromList(ascii.encode(sb.toString()));
  }
}
