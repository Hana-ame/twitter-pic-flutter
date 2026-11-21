// media_http_client.dart
// 媒体下载与本机 ECH 代理复用的共享 HttpClient 连接池。
//
// 背景：此前 ProgressiveImageProvider（每张图）与详情页批量下载（每个文件）
// 每次请求都新建一个 HttpClient() 并在结束后 client.close(force: true)，
// 导致本机回环 127.0.0.1:<port> 的 HTTP Keep-Alive 连接无法复用，高并发
// 刷图和批量下载时反复建连/拆连。
//
// 这里提供共享实例（带连接数上限与空闲超时），超时控制改为请求级 abort，
// 不再因单条请求超时而强关整个客户端连接池。

import 'dart:io';

import 'package:flutter/foundation.dart';

class MediaHttpClient {
  MediaHttpClient._();

  static HttpClient? _shared;

  /// 全局复用的媒体 HttpClient 实例。
  ///
  /// - [maxConnectionsPerHost] 限制单主机（主要是本机 127.0.0.1 代理）并发连接数，
  ///   防止快速滑动列表时瞬时打开过多回环 socket；
  /// - [idleTimeout] 保持 30 秒空闲复用窗口，兼顾连接复用与资源释放。
  static HttpClient get shared {
    return _shared ??= _createClient();
  }

  static HttpClient _createClient() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    client.idleTimeout = const Duration(seconds: 30);
    client.maxConnectionsPerHost = 12;
    return client;
  }

  /// 释放共享连接池（应用退出或代理重启后需要清理旧连接时调用）。
  static void reset({bool force = false}) {
    final old = _shared;
    _shared = null;
    old?.close(force: force);
  }

  @visibleForTesting
  static void resetForTests() => reset(force: true);
}
