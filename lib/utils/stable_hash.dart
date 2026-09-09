// 稳定哈希：为缓存文件名等场景提供跨运行一致的 key。
//
// String.hashCode 不保证跨运行/平台稳定，且只有 32 位——用作视频
// spool 文件名时，重启后缓存全部失效，不同 URL 还可能撞名互相覆盖。
// 这里用 FNV-1a 64 位：实现简单、分布均匀、无依赖。

/// 返回输入字符串的 FNV-1a 64 位哈希，16 位小写十六进制（零填充）。
String stableHash(String input) {
  final offset64 = BigInt.from(0xcbf29ce484222325);
  final prime64 = BigInt.from(0x100000001b3);
  final mask64 = BigInt.from(0xFFFFFFFFFFFFFFFF);
  
  BigInt h = offset64;
  for (final c in input.codeUnits) {
    h = h ^ BigInt.from(c);
    h = (h * prime64) & mask64;
  }
  final hex = h.toRadixString(16);
  return hex.padLeft(16, '0');
}
