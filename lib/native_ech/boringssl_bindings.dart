// BoringSSL dart:ffi 绑定骨架（PoC）。
//
// ⚠️ M1 未完成：以下签名按 BoringSSL 公开头文件整理，但【未经编译验证】，
//    落地时必须对照 ssl.h / ssl3.h / x509.h 逐个核对（尤其 ECH 系列
//    属 draft 演进 API）。锁 commit 编译：doc/native_ech_poc.md 风险表。
//
// 设计：
//  - 库名 libboringssl.so / boringssl.dll，与业务库 libechproxy 互不干扰；
//  - 握手采用 memory BIO 模式（不占 fd），TCP 流由 Dart Socket 泵入，
//    这样"流式"完全由 Dart Stream 驱动；
//  - 所有 native 调用集中在 [_BoringSsl] 内，上层只见 Dart 对象。
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---- 不透明类型 -----------------------------------------------------------
final class OpaqueSslCtx extends Opaque {}

final class OpaqueSsl extends Opaque {}

final class OpaqueBio extends Opaque {}

final class OpaqueBioMethod extends Opaque {}

final class OpaqueX509Store extends Opaque {}

// ---- 函数签名 -------------------------------------------------------------
typedef _BioNewNative = Pointer<OpaqueBio> Function(Pointer<OpaqueBioMethod>);
typedef _BioNewDart = Pointer<OpaqueBio> Function(Pointer<OpaqueBioMethod>);

typedef _SslCtxNewNative = Pointer<OpaqueSslCtx> Function();
typedef _SslCtxNewDart = Pointer<OpaqueSslCtx> Function();

typedef _SslNewNative = Pointer<OpaqueSsl> Function(Pointer<OpaqueSslCtx>);
typedef _SslNewDart = Pointer<OpaqueSsl> Function(Pointer<OpaqueSslCtx>);

// int SSL_CTX_set1_ech_config_list(SSL_CTX *, const uint8_t *ech_configs, size_t ech_configs_len)
typedef _SetEchListNative = Int32 Function(
    Pointer<OpaqueSslCtx>, Pointer<Uint8>, Size);
typedef _SetEchListDart = int Function(
    Pointer<OpaqueSslCtx>, Pointer<Uint8>, int);

// int SSL_set_tlsext_host_name(SSL *, const char *) —— 宏展开为 SSL_ctrl
typedef _SetHostNameNative = Int32 Function(Pointer<OpaqueSsl>, Pointer<Utf8>);
typedef _SetHostNameDart = int Function(Pointer<OpaqueSsl>, Pointer<Utf8>);

typedef _SetBioNative = Void Function(
    Pointer<OpaqueSsl>, Pointer<OpaqueBio>, Pointer<OpaqueBio>);
typedef _SetBioDart = void Function(
    Pointer<OpaqueSsl>, Pointer<OpaqueBio>, Pointer<OpaqueBio>);

typedef _ConnectNative = Int32 Function(Pointer<OpaqueSsl>);
typedef _ConnectDart = int Function(Pointer<OpaqueSsl>);

typedef _ReadNative = Int32 Function(
    Pointer<OpaqueSsl>, Pointer<Uint8>, Int32);
typedef _ReadDart = int Function(Pointer<OpaqueSsl>, Pointer<Uint8>, int);

typedef _WriteNative = Int32 Function(
    Pointer<OpaqueSsl>, Pointer<Uint8>, Int32);
typedef _WriteDart = int Function(Pointer<OpaqueSsl>, Pointer<Uint8>, int);

typedef _GetErrorNative = Int32 Function(Pointer<OpaqueSsl>, Int32);
typedef _GetErrorDart = int Function(Pointer<OpaqueSsl>, int);

// int SSL_ech_accepted(const SSL *)
typedef _EchAcceptedNative = Int32 Function(Pointer<OpaqueSsl>);
typedef _EchAcceptedDart = int Function(Pointer<OpaqueSsl>);

typedef _FreeSslNative = Void Function(Pointer<OpaqueSsl>);
typedef _FreeSslDart = void Function(Pointer<OpaqueSsl>);

typedef _FreeSslCtxNative = Void Function(Pointer<OpaqueSslCtx>);
typedef _FreeSslCtxDart = void Function(Pointer<OpaqueSslCtx>);

typedef _FreeBioNative = Void Function(Pointer<OpaqueBio>);
typedef _FreeBioDart = void Function(Pointer<OpaqueBio>);

class BoringSslLoadException implements Exception {
  final String message;
  BoringSslLoadException(this.message);
  @override
  String toString() => 'BoringSslLoadException: $message';
}

/// 加载并解析符号。加载失败（库不存在）返回 null——调用方回退 Go FFI 通道。
BoringSsl? tryLoadBoringSsl() {
  final String name;
  if (Platform.isWindows) {
    name = 'boringssl.dll';
  } else if (Platform.isAndroid || Platform.isLinux) {
    name = 'libboringssl.so';
  } else if (Platform.isMacOS) {
    name = 'libboringssl.dylib';
  } else {
    return null;
  }
  DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open(name);
  } catch (_) {
    return null;
  }
  try {
    return BoringSsl._(lib);
  } catch (_) {
    return null;
  }
}

class BoringSsl {
  final DynamicLibrary _lib;

  late final _BioNewDart bioNew;
  late final _SslCtxNewDart sslCtxNew;
  late final _SslNewDart sslNew;
  late final _SetEchListDart setEchConfigList;
  late final _SetHostNameDart setHostName;
  late final _SetBioDart setBio;
  late final _ConnectDart connect;
  late final _ReadDart read;
  late final _WriteDart write;
  late final _GetErrorDart getError;
  late final _EchAcceptedDart echAccepted;
  late final _FreeSslDart freeSsl;
  late final _FreeSslCtxDart freeSslCtx;
  late final _FreeBioDart freeBio;

  // TODO(M1): BIO_s_mem / SSL_CTX_set_min_proto_version(TLS1_3) /
  //           SSL_CTX_set_verify + X509 store load / SSL_get0_param +
  //           X509_VERIFY_PARAM_set1_host（或 SSL_set1_host）/ SSL_shutdown
  //           的签名同样需要补齐。

  BoringSsl._(this._lib) {
    Pointer<T> lookup<T extends NativeType>(String symbol) =>
        _lib.lookup<T>(symbol);

    bioNew = lookup<NativeFunction<_BioNewNative>>('BIO_new').asFunction();
    sslCtxNew =
        lookup<NativeFunction<_SslCtxNewNative>>('SSL_CTX_new').asFunction();
    sslNew = lookup<NativeFunction<_SslNewNative>>('SSL_new').asFunction();
    setEchConfigList = lookup<NativeFunction<_SetEchListNative>>(
            'SSL_CTX_set1_ech_config_list')
        .asFunction();
    setHostName = lookup<NativeFunction<_SetHostNameNative>>(
            'SSL_set_tlsext_host_name') // 宏！见下方说明
        .asFunction();
    setBio = lookup<NativeFunction<_SetBioNative>>('SSL_set_bio').asFunction();
    connect = lookup<NativeFunction<_ConnectNative>>('SSL_connect').asFunction();
    read = lookup<NativeFunction<_ReadNative>>('SSL_read').asFunction();
    write = lookup<NativeFunction<_WriteNative>>('SSL_write').asFunction();
    getError = lookup<NativeFunction<_GetErrorNative>>('SSL_get_error')
        .asFunction();
    echAccepted = lookup<NativeFunction<_EchAcceptedNative>>('SSL_ech_accepted')
        .asFunction();
    freeSsl = lookup<NativeFunction<_FreeSslNative>>('SSL_free').asFunction();
    freeSslCtx =
        lookup<NativeFunction<_FreeSslCtxNative>>('SSL_CTX_free').asFunction();
    freeBio = lookup<NativeFunction<_FreeBioNative>>('BIO_free').asFunction();

    // ⚠️ SSL_set_tlsext_host_name 在 BoringSSL 是宏（展开为 SSL_ctrl），
    //    FFI 无法直接 lookup 宏名。M1 需改为调 SSL_ctrl(TLSEXT_NAMETYPE_host_name)
    //    或在包装 C 层补一个壳函数。此处保留占位以便编译期暴露问题。
  }

  /// ECHConfigList 字节直接透传（wire 格式），native 侧拷贝后使用。
  Pointer<Uint8> allocBytes(Uint8List bytes) {
    final ptr = calloc<Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    return ptr;
  }
}
