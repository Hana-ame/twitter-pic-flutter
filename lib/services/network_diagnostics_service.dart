// network_diagnostics_service.dart
// 设置页网络诊断探针与 JSON 结构校验，从 SettingsScreen 拆出，便于独立维护与复用。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';

import '../api/twitter_api.dart';
import '../widgets/progressive_image.dart';

class DiagItem {
  final String label;
  final String result;
  final bool running;
  final bool ok;

  const DiagItem({
    required this.label,
    this.result = '',
    this.running = false,
    this.ok = true,
  });
}

class RawJsonResult {
  final int statusCode;
  final Map<String, String> headers;
  final String decodeMethod;
  final int bytes;
  final Map<String, dynamic>? json;
  final String? error;

  const RawJsonResult({
    required this.statusCode,
    required this.headers,
    this.decodeMethod = '',
    this.bytes = 0,
    this.json,
    this.error,
  });
}

class NetworkDiagnosticsService {
  NetworkDiagnosticsService._();

  /// 发起一次 HTTP 探测，只读前 [maxReadBytes] 字节并返回简短结果文本。
  static Future<String> httpProbe(
    String url, {
    int timeoutSec = 20,
    int maxReadBytes = 64 * 1024,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: timeoutSec);
    final sw = Stopwatch()..start();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(Duration(seconds: timeoutSec));
      final res = await req.close().timeout(Duration(seconds: timeoutSec));
      final len = res.contentLength;
      var got = 0;
      await for (final chunk
          in res.timeout(Duration(seconds: timeoutSec), onTimeout: (s) {
        s.addError(TimeoutException('body 读取超时', Duration(seconds: timeoutSec)));
      })) {
        got += chunk.length;
        if (got >= maxReadBytes) break;
      }
      return 'HTTP ${res.statusCode} · ${sw.elapsedMilliseconds}ms · ${len >= 0 ? len : '?'}B (读 ${got}B)';
    } catch (e) {
      return '失败: ${sw.elapsedMilliseconds}ms · $e';
    } finally {
      client.close(force: true);
    }
  }

  /// Range 分段探测（验证上游是否支持 206 + Content-Range）。
  static Future<String> rangeProbe(String url, {int timeoutSec = 20}) async {
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: timeoutSec);
    final sw = Stopwatch()..start();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(Duration(seconds: timeoutSec));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final res = await req.close().timeout(Duration(seconds: timeoutSec));
      final cr = res.headers.value(HttpHeaders.contentRangeHeader) ?? '-';
      final ar = res.headers.value('accept-ranges') ?? '-';
      final cl = res.headers.value(HttpHeaders.contentLengthHeader) ?? '-';
      var got = 0;
      await for (final chunk in res) {
        got += chunk.length;
        if (got > 8 * 1024) break;
      }
      final detail =
          'HTTP ${res.statusCode} · Content-Range: $cr · Accept-Ranges: $ar · Content-Length: $cl · 收到 ${got}B · ${sw.elapsedMilliseconds}ms';
      return res.statusCode == 206 ? detail : '失败: Range 未被支持 → $detail';
    } catch (e) {
      return '失败: ${sw.elapsedMilliseconds}ms · $e';
    } finally {
      client.close(force: true);
    }
  }

  /// 使用与生产一致的 [ProgressiveImageProvider] 验证图片加载与解码。
  static Future<String> imageDecodeProbe(String url,
      {int timeoutSec = 30}) async {
    final sw = Stopwatch()..start();
    final completer = Completer<String>();
    final stream =
        ProgressiveImageProvider(url).resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!completer.isCompleted) {
          completer.complete(
              '解码成功 ${info.image.width}x${info.image.height} · ${sw.elapsedMilliseconds}ms');
        }
      },
      onError: (e, _) {
        stream.removeListener(listener);
        if (!completer.isCompleted) {
          completer.complete('失败: ${sw.elapsedMilliseconds}ms · $e');
        }
      },
    );
    stream.addListener(listener);
    return completer.future.timeout(
      Duration(seconds: timeoutSec),
      onTimeout: () {
        stream.removeListener(listener);
        return '失败: ${timeoutSec}s 超时（连上但没出图）';
      },
    );
  }

  /// 抓取 `<username>.json.gz`，返回响应头、编码方式与原始 JSON。
  static Future<RawJsonResult> fetchRawJson(String username) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final date = DateTime.now().toIso8601String().split('T')[0];
      final port = TwitterApi.proxyPort;
      final url = port != null
          ? 'http://127.0.0.1:$port/api/twitter/$username.json.gz?t=$date'
          : '$kApiBase/$username.json.gz?t=$date';
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final res = await req.close().timeout(const Duration(seconds: 20));
      final headers = <String, String>{
        'content-type': res.headers.value('content-type') ?? '?',
        'content-encoding': res.headers.value('content-encoding') ?? '无',
        'content-length': res.headers.value('content-length') ?? '?',
      };
      if (res.statusCode != 200) {
        return RawJsonResult(
          statusCode: res.statusCode,
          headers: headers,
          error: 'HTTP ${res.statusCode}',
        );
      }
      final bytes = await res
          .timeout(const Duration(seconds: 45), onTimeout: (s) {
            s.addError(TimeoutException(
                'body 读取超时', const Duration(seconds: 45)));
          })
          .fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
      var text = '';
      var method = 'utf8';
      try {
        text = utf8.decode(bytes);
      } catch (_) {
        text = utf8.decode(gzip.decode(bytes));
        method = 'gzip+utf8';
      }
      final decoded = jsonDecode(text);
      return RawJsonResult(
        statusCode: res.statusCode,
        headers: headers,
        decodeMethod: method,
        bytes: bytes.length,
        json: decoded is Map<String, dynamic> ? decoded : null,
      );
    } catch (e) {
      return RawJsonResult(statusCode: 0, headers: const {}, error: '$e');
    } finally {
      client.close(force: true);
    }
  }

  /// 检查 JSON 字段是否匹配模型期望的 key。
  static String checkJsonFields(RawJsonResult res) {
    final buf = StringBuffer();
    buf.writeln('HTTP ${res.statusCode}');
    buf.writeln('content-type: ${res.headers['content-type']}');
    buf.writeln('content-encoding: ${res.headers['content-encoding']}');
    if (res.error != null) {
      buf.writeln('错误: ${res.error}');
      return buf.toString();
    }
    buf.writeln('解码: ${res.decodeMethod} · ${res.bytes}B');
    final json = res.json;
    if (json == null) {
      buf.writeln('JSON 非对象');
      return buf.toString();
    }

    final tl = json['timeline'];
    buf.writeln('顶层字段: ${json.keys.join(', ')}');
    buf.writeln('timeline: ${tl is List ? '${tl.length} 条' : '非数组!'}');
    if (tl is List && tl.isNotEmpty && tl.first is Map) {
      const need = ['url', 'type', 'date'];
      final first = tl.first as Map;
      for (final k in need) {
        buf.writeln("timeline[0].'$k' ${first.containsKey(k) ? '✓' : '✗ 缺失'}");
      }
      final sample = first.entries.take(3).map((e) {
        final v = e.value.toString();
        return "'${e.key}': ${v.length > 50 ? '${v.substring(0, 50)}…' : v}";
      }).join(' | ');
      buf.writeln('样例: $sample');
    }

    final info = json['account_info'];
    if (info is Map) {
      const need = ['name', 'nick', 'profile_image'];
      for (final k in need) {
        buf.writeln("account_info.'$k' ${info.containsKey(k) ? '✓' : '✗ 缺失'}");
      }
      buf.writeln('头像: ${info['profile_image']}');
    } else {
      buf.writeln('account_info: 缺失或非对象');
    }
    return buf.toString();
  }

  /// 判定一次诊断结果是否“通过”。
  static bool passed(String result) {
    if (result.startsWith('失败') || result.contains('（跳过）')) return false;
    final m = RegExp(r'HTTP (\d{3})').firstMatch(result);
    if (m != null) {
      final code = int.parse(m.group(1)!);
      return code >= 200 && code < 400;
    }
    return !result.contains('✗');
  }
}
