// ech_url.dart
// URL 重写工具：将原始 Twitter CDN URL 改写为走本机 ECH 代理的地址。
//
// 用法：
//   final port = await proxy.start(bootstrapIp: dohIp);
//   Image.network(EchUrl.rewrite('https://pbs.twimg.com/media/photo.jpg', port));
//
// 原理：
//   原始 URL:  https://pbs.twimg.com/media/photo.jpg?token=abc
//   代理 URL:  http://127.0.0.1:12345/media/photo.jpg?token=abc
//
//   本机代理收到 GET /media/photo.jpg?token=abc
//   → 拼出 https://video-cf.twimg.com/media/photo.jpg?token=abc
//   → ECH fetch → 流式回写

class EchUrl {
  /// 将原始 URL 改写为走本机 ECH 代理。
  ///
  /// [url] 原始 URL，如 `https://pbs.twimg.com/media/G3SXX_vWwAASvYp?format=jpg&name=orig`
  /// [port] 代理监听端口（由 `ProxyManager.start()` 返回）
  /// [host] 本机代理地址，默认 `127.0.0.1`
  ///
  /// 返回改写后的 URL 字符串。
  /// 铁律：不要动 path，只动 hostname。完整路径和所有参数（如 ?format=jpg&name=orig）原封不动保留。
  static String rewrite(String url, int port, {String host = '127.0.0.1'}) {
    final match = RegExp(r'^https?://[^/]+').firstMatch(url);
    if (match != null) {
      return url.replaceFirst(RegExp(r'^https?://[^/]+'), 'http://$host:$port');
    }
    final path = url.startsWith('/') ? url : '/$url';
    return 'http://$host:$port$path';
  }

  /// 将原始 URL 改写为 Uri 对象（适合直接传给 networkUrl / getUrl）。
  static Uri rewriteToUri(String url, int port, {String host = '127.0.0.1'}) {
    return Uri.parse(rewrite(url, port, host: host));
  }

  /// 判断一个 URL 是否已经是代理 URL（避免重复改写）。
  static bool isProxyUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.scheme == 'http' &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost');
  }

  /// 从代理 URL 中提取原始目标 URL（调试用）。
  /// 同样只动 hostname，保留完整路径与 query。
  static String extractTarget(String proxyUrl) {
    final match = RegExp(r'^http://[^/]+').firstMatch(proxyUrl);
    if (match != null) {
      return proxyUrl.replaceFirst(
          RegExp(r'^http://[^/]+'), 'https://video-cf.twimg.com');
    }
    final path = proxyUrl.startsWith('/') ? proxyUrl : '/$proxyUrl';
    return 'https://video-cf.twimg.com$path';
  }
}
