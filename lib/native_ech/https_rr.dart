// 通过 DoH 查询域名的 HTTPS(type 65 / SVCB)记录并提取 ech 参数。
//
// ECH 客户端需要目标的 ECHConfigList 字节，它由权威侧发布在该域名
// HTTPS 记录的 `ech=` SvcParam 中。国内公共 DNS 常把 ech 参数剥掉，
// 所以端点做成列表逐个尝试（moonchan 优先，公共 DoH 兜底）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 一条 DoH JSON Answer 里 type=65 的原始 data（presentation 格式），例如：
/// `1 . alpn="h2,h3" ipv6hint=2606:4700::1 ech=AEX+DQB...`
/// 解析规则见 RFC 9460 §2.2（SvcParams）：key=value；含特殊字符的值
/// 用双引号包裹，值内 `\;` `\,` 转义。
Uint8List? extractEchFromHttpsRr(String rdata) {
  final params = parseSvcParams(rdata);
  final ech = params['ech'];
  if (ech == null || ech.isEmpty) return null;
  try {
    return base64.decode(ech);
  } on FormatException {
    return null;
  }
}

/// 把 SvcParams 段解析成 key → value 映射（value 已去引号、已反转义）。
///
/// 输入不含 SvcPriority 与 TargetName 前缀时也能工作（按 token 扫描，
/// 遇到 `key=value` 形态即收）。未知 key 原样保留，不丢数据。
Map<String, String> parseSvcParams(String rdata) {
  final result = <String, String>{};
  var i = 0;
  final n = rdata.length;

  String nextToken() {
    // 跳过空白
    while (i < n && _isWs(rdata[i])) {
      i++;
    }
    if (i >= n) return '';
    final start = i;
    while (i < n && !_isWs(rdata[i])) {
      if (rdata[i] == '"') {
        // 引号段整体吞掉（引号内可能有空格）
        i++;
        while (i < n && rdata[i] != '"') {
          if (rdata[i] == '\\' && i + 1 < n) i++; // 跳过转义字符
          i++;
        }
        if (i < n) i++; // 收尾引号
      } else if (rdata[i] == '\\' && i + 1 < n) {
        i += 2; // 反斜杠转义（\; \, 等）
      } else {
        i++;
      }
    }
    return rdata.substring(start, i);
  }

  while (true) {
    final tok = nextToken();
    if (tok.isEmpty) break;
    final eq = tok.indexOf('=');
    if (eq <= 0) continue; // priority/target 或畸形 token，跳过
    final key = tok.substring(0, eq).toLowerCase();
    var value = tok.substring(eq + 1);
    value = _unquote(value);
    result[key] = value;
  }
  return result;
}

bool _isWs(String c) => c == ' ' || c == '\t';

String _unquote(String v) {
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    v = v.substring(1, v.length - 1);
  }
  // presentation 转义："\;" -> ";"，"\\x" -> "x"
  final sb = StringBuffer();
  for (var i = 0; i < v.length; i++) {
    if (v[i] == '\\' && i + 1 < v.length) {
      sb.write(v[i + 1]);
      i++;
    } else {
      sb.write(v[i]);
    }
  }
  return sb.toString();
}

class HttpsRrEchFetcher {
  /// 依次尝试的 DoH(JSON) 端点。`{host}` 占位符会被替换。
  /// 注意：部分解析器会对未注册域过滤 ech 参数，端点顺序即信任顺序。
  final List<Uri> endpoints;
  final HttpClient _client;

  HttpsRrEchFetcher({
    List<Uri>? endpoints,
    HttpClient? client,
  })  : _client = client ?? HttpClient(),
        endpoints = endpoints ??
            [
              Uri.parse('https://moonchan.xyz/doh?dns='),
              Uri.parse('https://1.1.1.1/dns-query?dns='),
              Uri.parse('https://8.8.8.8/resolve?dns='),
            ];

  Future<void> dispose() => _client.close();

  Duration timeoutPerEndpoint = const Duration(seconds: 8);

  /// 返回 [host] 的 ECHConfigList 字节；拿不到返回 null（不抛异常，
  /// 由调用方决定回退策略——比如走 Go FFI 通道）。
  Future<Uint8List?> fetchEchConfigList(
    String host, {
    Iterable<Uri>? overrideEndpoints,
  }) async {
    for (final base in overrideEndpoints ?? endpoints) {
      try {
        final uri = base.replace(queryParameters: {
          ...base.queryParameters,
          'name': host,
          'type': '65',
        });
        final req = await _client
            .getUrl(uri)
            .timeout(timeoutPerEndpoint);
        req.headers.set('Accept', 'application/dns-json');
        final resp = await req.close().timeout(timeoutPerEndpoint);
        final body =
            await resp.transform(utf8.decoder).join().timeout(timeoutPerEndpoint);
        if (resp.statusCode != 200) continue;
        final ech = extractEchFromAnswer(body);
        if (ech != null) return ech;
      } catch (_) {
        continue; // 单端点失败换下一个
      }
    }
    return null;
  }

  /// 从 DoH JSON 应答文本中提取第一条带 ech 的 HTTPS 记录值。
  static Uint8List? extractEchFromAnswer(String body) {
    dynamic json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return null;
    }
    final answers = json is Map ? json['Answer'] : null;
    if (answers is! List) return null;
    for (final ans in answers) {
      if (ans is Map && ans['type'] == 65) {
        final data = ans['data'];
        if (data is String) {
          final bytes = extractEchFromHttpsRr(data);
          if (bytes != null) return bytes;
        }
      }
    }
    return null;
  }
}
