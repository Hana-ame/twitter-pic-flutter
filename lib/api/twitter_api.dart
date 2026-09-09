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
  static final Map<String, UserMetaData> _metaCache = {};

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

  Future<UserMetaData> getMetaData(String username, {String? t}) async {
    final cached = _metaCache[username];
    if (cached != null) return cached;

    final path = '$username.json.gz';
    final resp = await _dio.get(
      path,
      queryParameters: {
        't': t ?? DateTime.now().toIso8601String().split('T')[0],
      },
    );
    final json = resp.data as Map<String, dynamic>;
    final meta = UserMetaData.fromJson(json);
    _metaCache[username] = meta;
    return meta;
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
