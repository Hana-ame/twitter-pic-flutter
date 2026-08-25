// BoringSSL dart:ffi 绑定（PoC，M2）。
//
// ⚠️ 签名按 BoringSSL 公开头文件整理，【尚未经编译验证】——以
//    native_ech_poc.yml 的符号核对 job + 首次编译为准。
//    ECH 系列属 draft 演进 API：构建时锁定 boringssl commit。
//
// 宏处理约定（FFI 无法 lookup 宏）：
//  - SSL_set_tlsext_host_name(ssl, name) == SSL_ctrl(ssl, 55 /*SET_TLSEXT_HOSTNAME*/, 0, name)
//  - SSL_CTX_set_min_proto_version(ctx, v) == SSL_CTX_ctrl(ctx, 123 /*SET_MIN_PROTO_VERSION*/, v, NULL)
//    （控制码与 OpenSSL 共用，多年未变）
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---- 不透明类型 -----------------------------------------------------------
final class OpaqueSslCtx extends Opaque {}

final class OpaqueSsl extends Opaque {}

final class OpaqueBio extends Opaque {}

final class OpaqueBioMethod extends Opaque {}

// ---- SSL_ctrl 控制码 / 协议常量（与 OpenSSL 共用的稳定数值） ----------------
const int sslCtrlSetTlsextHostname = 55;
const int sslCtrlSetMinProtoVersion = 123;
const int tls13Version = 0x0304;

// ---- SSL_get_error 返回值 --------------------------------------------------
const int sslErrorSsl = 1;
const int sslErrorWantRead = 2;
const int sslErrorWantWrite = 3;
const int sslErrorSyscall = 5;
const int sslErrorZeroReturn = 6;

// ---- 函数签名 -------------------------------------------------------------
typedef _BioNewNative = Pointer<OpaqueBio> Function(Pointer<OpaqueBioMethod>);
typedef _BioNewDart = Pointer<OpaqueBio> Function(Pointer<OpaqueBioMethod>);

typedef _BioMethodMemNative = Pointer<OpaqueBioMethod> Function();
typedef _BioMethodMemDart = Pointer<OpaqueBioMethod> Function();

typedef _BioReadNative = Int32 Function(
    Pointer<OpaqueBio>, Pointer<Uint8>, Int32);
typedef _BioReadDart = int Function(Pointer<OpaqueBio>, Pointer<Uint8>, int);

typedef _BioWriteNative = Int32 Function(
    Pointer<OpaqueBio>, Pointer<Uint8>, Int32);
typedef _BioWriteDart = int Function(Pointer<OpaqueBio>, Pointer<Uint8>, int);

typedef _BioCtrlPendingNative = Size Function(Pointer<OpaqueBio>);
typedef _BioCtrlPendingDart = int Function(Pointer<OpaqueBio>);

typedef _SslCtxNewNative = Pointer<OpaqueSslCtx> Function();
typedef _SslCtxNewDart = Pointer<OpaqueSslCtx> Function();

typedef _SslNewNative = Pointer<OpaqueSsl> Function(Pointer<OpaqueSslCtx>);
typedef _SslNewDart = Pointer<OpaqueSsl> Function(Pointer<OpaqueSslCtx>);

typedef _SslCtxCtrlNative = Int64 Function(
    Pointer<OpaqueSslCtx>, Int32, Int64, Pointer<Void>);
typedef _SslCtxCtrlDart = int Function(
    Pointer<OpaqueSslCtx>, int, int, Pointer<Void>);

typedef _SslCtrlNative = Int64 Function(
    Pointer<OpaqueSsl>, Int32, Int32, Pointer<Void>);
typedef _SslCtrlDart = int Function(
    Pointer<OpaqueSsl>, int, int, Pointer<Void>);

// int SSL_CTX_set1_ech_config_list(SSL_CTX *, const uint8_t *, size_t)
typedef _SetEchListNative = Int32 Function(
    Pointer<OpaqueSslCtx>, Pointer<Uint8>, Size);
typedef _SetEchListDart = int Function(
    Pointer<OpaqueSslCtx>, Pointer<Uint8>, int);

typedef _SetBioNative = Void Function(
    Pointer<OpaqueSsl>, Pointer<OpaqueBio>, Pointer<OpaqueBio>);
typedef _SetBioDart = void Function(
    Pointer<OpaqueSsl>, Pointer<OpaqueBio>, Pointer<OpaqueBio>);

typedef _SetConnectStateNative = Void Function(Pointer<OpaqueSsl>);
typedef _SetConnectStateDart = void Function(Pointer<OpaqueSsl>);

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

typedef _ShutdownNative = Int32 Function(Pointer<OpaqueSsl>);
typedef _ShutdownDart = int Function(Pointer<OpaqueSsl>);

typedef _FreeSslNative = Void Function(Pointer<OpaqueSsl>);
typedef _FreeSslDart = void Function(Pointer<OpaqueSsl>);

typedef _FreeSslCtxNative = Void Function(Pointer<OpaqueSslCtx>);
typedef _FreeSslCtxDart = void Function(Pointer<OpaqueSslCtx>);

class BoringSslLoadException implements Exception {
  final String message;
  BoringSslLoadException(this.message);
  @override
  String toString() => 'BoringSslLoadException: $message';
}

/// 加载并解析符号。库不存在返回 null —— 上层回退 Go FFI 通道。
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
  late final _BioMethodMemDart bioSMem;
  late final _BioReadDart bioRead;
  late final _BioWriteDart bioWrite;
  late final _BioCtrlPendingDart bioCtrlPending;
  late final _SslCtxNewDart sslCtxNew;
  late final _SslNewDart sslNew;
  late final _SslCtxCtrlDart sslCtxCtrl;
  late final _SslCtrlDart sslCtrl;
  late final _SetEchListDart setEchConfigList;
  late final _SetBioDart setBio;
  late final _SetConnectStateDart setConnectState;
  late final _ConnectDart connect;
  late final _ReadDart read;
  late final _WriteDart write;
  late final _GetErrorDart getError;
  late final _EchAcceptedDart echAccepted;
  late final _ShutdownDart shutdown;
  late final _FreeSslDart freeSsl;
  late final _FreeSslCtxDart freeSslCtx;

  // TODO(M1): 证书校验链路 —— SSL_CTX_set_verify + X509 store 装载
  //           （Android 系统 cacerts 目录 / Windows 打包 Mozilla bundle）、
  //           主机名校验（SSL_get0_param + X509_VERIFY_PARAM_set1_host 或等价）。
  //           未接通前 [EchSocket] 拒绝建立连接（宁可不工作也不裸奔）。

  BoringSsl._(this._lib) {
    Pointer<NativeFunction<T>> look<T extends NativeType>(String s) =>
        _lib.lookup<NativeFunction<T>>(s);

    bioNew = look<_BioNewNative>('BIO_new').asFunction();
    bioSMem = look<_BioMethodMemNative>('BIO_s_mem').asFunction();
    bioRead = look<_BioReadNative>('BIO_read').asFunction();
    bioWrite = look<_BioWriteNative>('BIO_write').asFunction();
    bioCtrlPending =
        look<_BioCtrlPendingNative>('BIO_ctrl_pending').asFunction();
    sslCtxNew = look<_SslCtxNewNative>('SSL_CTX_new').asFunction();
    sslNew = look<_SslNewNative>('SSL_new').asFunction();
    sslCtxCtrl = look<_SslCtxCtrlNative>('SSL_CTX_ctrl').asFunction();
    sslCtrl = look<_SslCtrlNative>('SSL_ctrl').asFunction();
    setEchConfigList =
        look<_SetEchListNative>('SSL_CTX_set1_ech_config_list').asFunction();
    setBio = look<_SetBioNative>('SSL_set_bio').asFunction();
    setConnectState =
        look<_SetConnectStateNative>('SSL_set_connect_state').asFunction();
    connect = look<_ConnectNative>('SSL_connect').asFunction();
    read = look<_ReadNative>('SSL_read').asFunction();
    write = look<_WriteNative>('SSL_write').asFunction();
    getError = look<_GetErrorNative>('SSL_get_error').asFunction();
    echAccepted = look<_EchAcceptedNative>('SSL_ech_accepted').asFunction();
    shutdown = look<_ShutdownNative>('SSL_shutdown').asFunction();
    freeSsl = look<_FreeSslNative>('SSL_free').asFunction();
    freeSslCtx = look<_FreeSslCtxNative>('SSL_CTX_free').asFunction();
  }

  /// 设置内层 SNI（真域名）。外层 SNI 由 ECHConfig 的 public_name 自动填充。
  bool setTlsextHostName(Pointer<OpaqueSsl> ssl, String host) {
    final p = host.toNativeUtf8();
    try {
      return sslCtrl(ssl, sslCtrlSetTlsextHostname, 0, p.cast<Void>()) == 1;
    } finally {
      calloc.free(p);
    }
  }

  void setMinProtoTls13(Pointer<OpaqueSslCtx> ctx) {
    sslCtxCtrl(ctx, sslCtrlSetMinProtoVersion, tls13Version, nullptr);
  }

  /// ECHConfigList wire 字节透传；native 会拷贝，调用后即可释放。
  int applyEchConfigList(Pointer<OpaqueSslCtx> ctx, Uint8List list) {
    final ptr = calloc<Uint8>(list.length);
    try {
      ptr.asTypedList(list.length).setAll(0, list);
      return setEchConfigList(ctx, ptr, list.length);
    } finally {
      calloc.free(ptr);
    }
  }
}
