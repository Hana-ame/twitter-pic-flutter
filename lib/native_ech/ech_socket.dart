// ECH over BoringSSL 的流式 socket（PoC，M2）。
//
// 模型：memory BIO 双缓冲 + Dart Socket 泵。
//   网络密文 → Socket.listen → rbio → SSL_read → 明文 Stream
//   明文写入 → SSL_write → wbio → Socket.add → 网络
// 握手与应用数据共用同一泵（SSL_connect / SSL_read 返回 WANT_READ 时
// 只是等下一个网络事件，不阻塞 UI）。
//
// ⚠️ 证书校验未接通（见 boringssl_bindings.dart TODO）：在接通前，
//    [connect] 直接抛错 —— 本类当前仅可用于 CI 冒烟，不可用于真实请求。
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'boringssl_bindings.dart';

class EchSocketException implements Exception {
  final String message;
  EchSocketException(this.message);
  @override
  String toString() => 'EchSocketException: $message';
}

class EchSocket {
  static const int _kBufSize = 16 * 1024;

  final BoringSsl bssl;
  // 可空：connect() 在证书校验接通前直接抛错，字段保持未赋值状态。
  Pointer<OpaqueSslCtx>? ctx;
  Pointer<OpaqueSsl>? ssl;
  Pointer<OpaqueBio>? rbio; // 网络来的密文写进这里
  Pointer<OpaqueBio>? wbio; // 要发出去的密文从这里读

  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;
  Pointer<Uint8>? _buf;
  final _plaintext = StreamController<List<int>>.broadcast();
  Completer<void>? _handshakeDone;
  bool _closed = false;

  /// 握手完成后为 true：ECH 被服务端接受。
  bool get echAccepted {
    final s = ssl;
    if (s == null || s == nullptr) return false;
    return bssl.echAccepted(s) == 1;
  }

  /// 解密后的明文流（应用数据）。
  Stream<List<int>> get plaintext => _plaintext.stream;

  EchSocket._(this.bssl);

  /// 建连 + ECH 握手。
  ///
  /// [echConfigList] 来自 https_rr.dart；[caBundlePath] 为证书校验的
  /// PEM bundle（未提供时拒绝连接 —— 见类注释）。
  static Future<EchSocket> connect(
    String host, {
    required Uint8List echConfigList,
    required String caBundlePath,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    // TODO(M1): 校验链路接通后移除此抛错并使用 caBundlePath。
    throw UnimplementedError(
        'EchSocket: certificate verification not wired yet (M1 pending)');

    /* ---- M2 实现骨架（校验接通后恢复） -------------------------------
    final bssl = tryLoadBoringSsl();
    if (bssl == null) {
      throw EchSocketException('boringssl native library not found');
    }
    final s = EchSocket._(bssl)
      ..ctx = bssl.sslCtxNew()
      ..ssl = nullptr
      ..rbio = bssl.bioNew(bssl.bioSMem())
      ..wbio = bssl.bioNew(bssl.bioSMem());
    if (s.ctx == nullptr || s.rbio == nullptr || s.wbio == nullptr) {
      s.dispose();
      throw EchSocketException('SSL_CTX/BIO alloc failed');
    }
    bssl.setMinProtoTls13(s.ctx);
    if (bssl.applyEchConfigList(s.ctx, echConfigList) != 1) {
      s.dispose();
      throw EchSocketException('invalid ECHConfigList');
    }
    s.ssl = bssl.sslNew(s.ctx);
    if (s.ssl == nullptr || !bssl.setTlsextHostName(s.ssl, host)) {
      s.dispose();
      throw EchSocketException('SSL_new / set hostname failed');
    }
    // TODO(M1): load CA bundle into ctx store + set verify host。

    s._socket = await Socket.connect(host, 443, timeout: timeout);
    s._buf = calloc<Uint8>(_kBufSize);
    bssl.setBio(s.ssl, s.rbio, s.wbio);
    bssl.setConnectState(s.ssl);
    s._socket!.listen(s._onNetworkData,
        onError: (Object e) => s._fail('socket error: $e'),
        onDone: () => s._fail('socket closed by peer'));
    s._handshakeDone = Completer<void>();
    s._driveHandshake();
    await s._handshakeDone!.future.timeout(timeout);
    return s;
    ---------------------------------------------------------------- */
  }

  /* ---- M2 实现骨架（随上方一起恢复） ---------------------------------
  void _onNetworkData(Uint8List data) {
    if (_closed) return;
    final p = calloc<Uint8>(data.length);
    try {
      p.asTypedList(data.length).setAll(0, data);
      while (true) {
        final n = bssl.bioWrite(rbio, p, data.length);
        if (n == data.length) break;
        if (n <= 0) return _fail('BIO_write failed'); // 内存 BIO 几乎不会满
      }
    } finally {
      calloc.free(p);
    }
    _pump();
  }

  void _driveHandshake() {
    while (!_closed) {
      _flushWbio();
      final ret = bssl.connect(ssl);
      if (ret == 1) {
        _flushWbio();
        if (!echAccepted) {
          _fail('ECH rejected by server');
          return;
        }
        _handshakeDone?.complete();
        _drainPlaintext(); // 握手期间可能已带应用数据
        _plaintext.add([]); // 空块作为“可发请求”信号
        return;
      }
      final err = bssl.getError(ssl, ret);
      _flushWbio();
      switch (err) {
        case sslErrorWantRead:
        case sslErrorWantWrite:
          return; // 等下一个网络事件再泵
        default:
          _fail('SSL_connect failed (ret=$ret err=$err)');
          return;
      }
    }
  }

  /// 把 wbio 里攒下的密文全部推到网络。
  void _flushWbio() {
    if (_closed || _socket == null) return;
    while (true) {
      final pending = bssl.bioCtrlPending(wbio);
      if (pending <= 0) break;
      final n = bssl.bioRead(
          wbio, _buf!, pending < _kBufSize ? pending : _kBufSize);
      if (n <= 0) break;
      _socket!.add(Uint8List.fromList(_buf!.asTypedList(n)));
    }
  }

  /// 尽量读出明文；WANT_READ 时停下等网络数据。
  void _drainPlaintext() {
    while (!_closed) {
      final n = bssl.read(ssl, _buf!, _kBufSize);
      if (n > 0) {
        _plaintext.add(Uint8List.fromList(_buf!.asTypedList(n)));
        continue;
      }
      final err = bssl.getError(ssl, n);
      if (err == sslErrorZeroReturn) return _close('peer closed');
      if (err == sslErrorWantRead || err == sslErrorWantWrite) {
        _flushWbio();
        return;
      }
      return _fail('SSL_read failed (err=$err)');
    }
  }

  /// 统一入口：任何状态变化后调用（网络来数据 / 写入明文后）。
  void _pump() {
    if (_closed) return;
    if (_handshakeDone?.isCompleted != true) {
      _driveHandshake();
    } else {
      _drainPlaintext();
    }
  }

  /// 发送明文（应用数据）。
  void add(List<int> data) {
    if (_closed) throw StateError('closed');
    final p = calloc<Uint8>(data.length);
    try {
      var off = 0;
      while (off < data.length) {
        p.asTypedList(data.length).setAll(off, data.sublist(off));
        final n = bssl.write(ssl, p, data.length - off);
        if (n <= 0) return _fail('SSL_write failed');
        off += n;
        _flushWbio();
      }
    } finally {
      calloc.free(p);
    }
  }

  void _fail(String msg) {
    if (_handshakeDone?.isCompleted == false) {
      _handshakeDone!.completeError(EchSocketException(msg));
    }
    _close(msg);
  }

  void _close(String reason) {
    if (_closed) return;
    _closed = true;
    _sub?.cancel();
    _socket?.destroy();
    _plaintext.close();
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    _socket?.destroy();
    _plaintext.close();
    final s0 = ssl; if (s0 != null && s0 != nullptr) bssl.freeSsl(s0); // 同时释放两个 BIO（所有权已移交）
    final c0 = ctx; if (c0 != null && c0 != nullptr) bssl.freeSslCtx(c0);
    if (_buf != null) calloc.free(_buf!);
  }
  ---------------------------------------------------------------- */
}
