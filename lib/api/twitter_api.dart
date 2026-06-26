// 与后端交互的 API 客户端，提供用户信息、标签、投票等接口
import 'dart:convert';
import 'dart:io';

import '../models/user.dart';

const _kApiBase = 'https://x.moonchan.xyz/api/twitter';

class TwitterApi {
  final HttpClient _client = HttpClient();
  static final Map<String, UserMetaData> _metaCache = {};

  Future<List<TwitterUser>> getUserList({String? after}) async {
    final uri = Uri.parse('$_kApiBase/').replace(queryParameters: {
      'list': 'users',
      if (after != null) 'after': after,
    });
    final req = await _client.getUrl(uri);
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    final list = jsonDecode(body) as List<dynamic>;
    return list.map((e) => TwitterUser.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<TwitterUser>> searchUserList(String by, String search) async {
    if (search.isEmpty) return [];
    final uri = Uri.parse('$_kApiBase/').replace(queryParameters: {
      'by': by,
      'search': search,
    });
    final req = await _client.getUrl(uri);
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    final list = jsonDecode(body) as List<dynamic>;
    return list.map((e) => TwitterUser.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<UserMetaData> getMetaData(String username, {String? t}) async {
    final cached = _metaCache[username];
    if (cached != null) return cached;
    final path = '$username.json.gz';
    final uri = Uri.parse('$_kApiBase/$path').replace(queryParameters: {
      't': t ?? DateTime.now().toIso8601String().split('T')[0],
    });
    final req = await _client.getUrl(uri);
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final meta = UserMetaData.fromJson(json);
    _metaCache[username] = meta;
    return meta;
  }

  Future<void> createMetaData(String username, {Map<String, dynamic>? body, bool doNotTag = true, bool doNotRenew = false}) async {
    final uri = Uri.parse('$_kApiBase/$username').replace(queryParameters: {
      if (doNotTag) 'do_not_tag': 'true',
      if (doNotRenew) 'do_not_renew': 'true',
    });
    final req = await _client.postUrl(uri);
    if (body != null) {
      req.headers.set('Content-Type', 'application/json');
      req.write(jsonEncode(body));
    }
    final resp = await req.close();
    if (resp.statusCode >= 400) {
      throw Exception('createMetaData failed: HTTP ${resp.statusCode}');
    }
  }

  Future<Map<String, dynamic>> getTags(String username) async {
    final uri = Uri.parse('$_kApiBase/tags/$username');
    final req = await _client.getUrl(uri);
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getEmojis(String username) async {
    final uri = Uri.parse('$_kApiBase/emojis').replace(queryParameters: {
      'username': username,
    });
    final req = await _client.getUrl(uri);
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<void> voteUpEmoji(String username, String emoji) async {
    final params = <String, String>{'username': username, 'emoji': emoji};
    final uri = Uri.parse('$_kApiBase/emojis').replace(queryParameters: params);
    final req = await _client.postUrl(uri);
    final resp = await req.close();
    if (resp.statusCode >= 400) {
      throw Exception('voteUpEmoji failed: HTTP ${resp.statusCode}');
    }
  }

  Future<Map<String, EmojiPeriodData>> getRanking() async {
    // The backend's ranking endpoint is broken; use emojis with empty username
    final uri = Uri.parse('$_kApiBase/emojis.json.gz');
    final req = await _client.getUrl(uri);
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    final raw = jsonDecode(body) as Map<String, dynamic>;
    return raw.map((k, v) => MapEntry(k, EmojiPeriodData.fromJson(v as Map<String, dynamic>)));
  }

  void dispose() {
    _client.close();
  }
}
