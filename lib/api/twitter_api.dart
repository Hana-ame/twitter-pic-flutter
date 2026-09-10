// 与后端交互的 API 客户端，提供用户信息、标签、投票等接口。
//
// 使用 Dio 替代原生 HttpClient，获得：
//   - 明确的 connectTimeout / receiveTimeout（15s）
//   - 结构化异常（DioException），可区分网络错误 vs HTTP 错误
//   - 全局拦截器支持（认证、日志、重试）
//   - 自动 JSON 反序列化

import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/user.dart';

const _kApiBase = 'https://x.moonchan.xyz/api/twitter';

/// 所有请求统一走本机 ECH 代理 endpoint（用户要求：request 一律访问代理）。
/// [ProxyManager] 启停时调用 [useProxyEndpoint] 注入/清除端口。
class ApiEndpoint {
  static int? proxyPort;

  /// 当前生效的 API baseUrl：代理在线 → 127.0.0.1:port/api/twitter；
  /// 代理未启动（开发/降级）→ 直连官方域名。
  static String get base {
    final p = proxyPort;
    return p != null ? 'http://127.0.0.1:$p/api/twitter' : _kApiBase;
  }

  static void useProxyEndpoint(int? port) => proxyPort = port;
}

/// 结构化 API 异常，包装 Dio 错误供 UI 层使用。
sealed class ApiException implements Exception {
  final String message;
  const ApiException(this.message);

  @override
  String toString() => message;
}

class NetworkException extends ApiException {
  const NetworkException(super.message);
}

class HttpException extends ApiException {
  final int statusCode;
  const HttpException(this.statusCode, super.message);
}

class UnknownException extends ApiException {
  const UnknownException(super.message);
}

class TwitterApi {
  // 缓存存 Future<UserMetaData> 而非结果：同一用户并发 getMetaData 复用
  // 同一个 in-flight 请求，避免并发 miss 全部各自拉取（重复流量）。
  static final Map<String, Future<UserMetaData>> _metaCache = {};
  // 缓存写入时间，配合 _kCacheTtl 过期——原静态缓存无 TTL 无上限，
  // 进程内无限增长且永不失效。
  static final Map<String, DateTime> _metaCacheTime = {};
  static const Duration _kCacheTtl = Duration(minutes: 10);

  late final Dio _dio;

  TwitterApi() {
    _dio = Dio(BaseOptions(
      baseUrl: ApiEndpoint.base,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      headers: {'User-Agent': 'TwitterPic/1.0'},
    ));

    // 全局拦截器：统一异常映射 + 动态 baseUrl（代理重启换端口后
    // 旧实例也要走新端口）。
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {
        final live = ApiEndpoint.base;
        if (o.baseUrl != live) o.baseUrl = live;
        h.next(o);
      },
      onError: (e, handler) {
        if (e.error is ApiException) {
          handler.reject(e);
        } else {
          handler.reject(DioException(
            requestOptions: e.requestOptions,
            type: e.type,
            error: _mapDioErrorToException(e),
          ));
        }
      },
    ));
  }

  Future<List<TwitterUser>> getUserList({String? after}) async {
    final resp = await _dio.get(
      '/',
      queryParameters: {
        'list': 'users',
        if (after != null) 'after': after,
      },
    );
    final decoded = resp.data;
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((e) => TwitterUser.fromJson(_asJsonMap(e, 'getUserList entry')))
        .toList();
  }

  Future<List<TwitterUser>> searchUserList(String by, String search) async {
    if (search.isEmpty) return [];
    final resp = await _dio.get(
      '/',
      queryParameters: {'by': by, 'search': search},
    );
    final decoded = resp.data;
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((e) => TwitterUser.fromJson(_asJsonMap(e, 'getUserList entry')))
        .toList();
  }

  Future<UserMetaData> getMetaData(String username, {String? t, bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = _metaCache[username];
      final cachedAt = _metaCacheTime[username];
      if (cached != null &&
          cachedAt != null &&
          DateTime.now().difference(cachedAt) < _kCacheTtl) {
        return cached;
      }
      // 过期丢弃，重新拉取。
      _metaCache.remove(username);
      _metaCacheTime.remove(username);
    }

    final inFlight = _fetchMetaData(username, t);
    _metaCache[username] = inFlight;
    _metaCacheTime[username] = DateTime.now();
    try {
      return await inFlight;
    } catch (_) {
      // 失败不进缓存，下次调用重试。
      _metaCache.remove(username);
      _metaCacheTime.remove(username);
      rethrow;
    }
  }

  /// 把响应体解析成 `Map<String, dynamic>`。
  ///
  /// Dio 在不同平台把 JSON 对象解成 `Map<String, dynamic>`、
  /// `Map<dynamic, dynamic>` 或（content-type 未识别时）未解码的 String。
  /// Dart 的泛型判定是严格的：`Map<dynamic, dynamic> is Map<String, dynamic>`
  /// 为 false，所以 `is! Map<String, dynamic>` 会把前两类误判成"非 JSON 响应"，
  /// 导致 metadata 全部失败——详情页显示"暂无内容"且头像全缺，
  /// 而 getUserList 用宽松的 `is! List` 判定不受影响。
  static Map<String, dynamic> _asJsonMap(dynamic raw, String context) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    throw UnknownException(
      '$context 返回非 JSON 响应（实际类型 ${raw.runtimeType}）',
    );
  }

  Future<UserMetaData> _fetchMetaData(String username, String? t) async {
    final resp = await _dio.get(
      '$username.json.gz',
      queryParameters: {
        't': t ?? DateTime.now().toIso8601String().split('T')[0],
      },
    );
    return UserMetaData.fromJson(_asJsonMap(resp.data, 'getMetaData($username)'));
  }

  Future<void> createMetaData(
    String username, {
    Map<String, dynamic>? body,
    bool doNotTag = true,
    bool doNotRenew = false,
  }) async {
    await _dio.post(
      username,
      data: body,
      queryParameters: {
        if (doNotTag) 'do_not_tag': 'true',
        if (doNotRenew) 'do_not_renew': 'true',
      },
    );
    // 写操作成功后清缓存：标签/屏蔽/内容更新后 UI 读缓存会得到脏数据。
    _metaCache.remove(username);
    _metaCacheTime.remove(username);
  }

  Future<Map<String, dynamic>> getTags(String username) async {
    final resp = await _dio.get('tags/$username');
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getEmojis(String username) async {
    final resp = await _dio.get(
      'emojis',
      queryParameters: {'username': username},
    );
    return resp.data as Map<String, dynamic>;
  }

  Future<void> voteUpEmoji(String username, String emoji) async {
    await _dio.post(
      'emojis',
      queryParameters: {'username': username, 'emoji': emoji},
    );
  }

  Future<Map<String, EmojiPeriodData>> getRanking() async {
    final resp = await _dio.get('emojis.json.gz');
    final raw = resp.data as Map<String, dynamic>;
    return raw.map(
        (k, v) => MapEntry(k, EmojiPeriodData.fromJson(v as Map<String, dynamic>)));
  }

  /// 将 DioException 映射为结构化 ApiException。
  ApiException _mapDioErrorToException(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return const NetworkException('连接超时');
      case DioExceptionType.receiveTimeout:
        return const NetworkException('响应超时');
      case DioExceptionType.connectionError:
        return const NetworkException('网络不可达');
      case DioExceptionType.badResponse:
        return HttpException(
            e.response?.statusCode ?? 0,
            'HTTP ${e.response?.statusCode}: ${e.response?.statusMessage}');
      default:
        return UnknownException(e.message ?? '未知错误');
    }
  }

  void dispose() {
    _dio.close(force: true);
  }
}
