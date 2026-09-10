// 与后端交互的 API 客户端，提供用户信息、标签、投票等接口。
//
// 使用 Dio 替代原生 HttpClient，获得：
//   - 明确的 connectTimeout / receiveTimeout（15s）
//   - 结构化异常（DioException），可区分网络错误 vs HTTP 错误
//   - 全局拦截器支持（认证、日志、重试）
//   - 自动 JSON 反序列化

import 'package:dio/dio.dart';

import '../models/user.dart';

const _kApiBase = 'https://x.moonchan.xyz/api/twitter';

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
      baseUrl: _kApiBase,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      headers: {'User-Agent': 'TwitterPic/1.0'},
    ));

    // 全局拦截器：统一异常映射
    _dio.interceptors.add(InterceptorsWrapper(
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
        .map((e) => TwitterUser.fromJson(e as Map<String, dynamic>))
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
        .map((e) => TwitterUser.fromJson(e as Map<String, dynamic>))
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

  Future<UserMetaData> _fetchMetaData(String username, String? t) async {
    final resp = await _dio.get(
      '$username.json.gz',
      queryParameters: {
        't': t ?? DateTime.now().toIso8601String().split('T')[0],
      },
    );
    final json = resp.data;
    // API 返回 HTML 错误页/空响应/解压失败时 resp.data 不是 Map，直接
    // as 转型会抛 TypeError 并绕过拦截器的异常映射。
    if (json is! Map<String, dynamic>) {
      throw UnknownException('getMetaData($username) 返回非 JSON 响应');
    }
    return UserMetaData.fromJson(json);
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
