import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class StorageService {
  static const _kFavMap = 'fav-map';
  static const _kBlockMap = 'block-map';
  static const _kTagRules = 'tag-rules';
  static const _kCustomTags = 'user_custom_tags';

  static bool _loaded = false;
  static Map<String, String> _memory = {};
  static File? _file;

  static Future<void> ensureInitialized() async {
    if (_loaded) return;
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/storage.json');
    if (await _file!.exists()) {
      try {
        final content = await _file!.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map) {
          _memory = decoded.cast<String, String>();
        }
      } catch (_) {}
    }
    _loaded = true;
  }

  static Future<void> _flush() async {
    await _file!.writeAsString(jsonEncode(_memory));
  }

  static Map<String, dynamic> _readMap(String key) {
    final s = _read(key);
    if (s.isEmpty) return {};
    try {
      final o = jsonDecode(s);
      if (o is Map) return o.cast<String, dynamic>();
    } catch (_) {}
    return {};
  }

  static void _writeMap(String key, Map<String, dynamic> value) {
    _write(key, jsonEncode(value));
  }

  static String _read(String key) => _memory[key] ?? '';
  static void _write(String key, String value) {
    _memory[key] = value;
    unawaited(_flush());
  }

  // --- fav-map ---
  static Map<String, dynamic> getFavMap() => _readMap(_kFavMap);
  static void setFavMap(Map<String, dynamic> map) => _writeMap(_kFavMap, map);
  static bool isFav(String username) => getFavMap()[username] == true;
  static void toggleFav(String username) {
    final map = getFavMap();
    if (map[username] == true) {
      map.remove(username);
    } else {
      map[username] = true;
    }
    setFavMap(map);
  }

  // --- block-map ---
  static Map<String, dynamic> getBlockMap() => _readMap(_kBlockMap);
  static void setBlockMap(Map<String, dynamic> map) => _writeMap(_kBlockMap, map);
  static bool isBlocked(String username) => getBlockMap()[username] == true;
  static void toggleBlock(String username) {
    final map = getBlockMap();
    if (map[username] == true) {
      map.remove(username);
    } else {
      map[username] = true;
    }
    setBlockMap(map);
  }

  // --- tag-rules ---
  static Map<String, dynamic> getTagRules() => _readMap(_kTagRules);
  static void setTagRules(Map<String, dynamic> rules) => _writeMap(_kTagRules, rules);

  static List<String> getHighlightTags() {
    final rules = getTagRules();
    final h = rules['highlight'];
    if (h is List) return h.cast<String>();
    return [];
  }

  static List<String> getBlockTags() {
    final rules = getTagRules();
    final b = rules['block'];
    if (b is List) return b.cast<String>();
    return [];
  }

  static void setHighlightTags(List<String> tags) {
    final rules = getTagRules();
    rules['highlight'] = tags;
    setTagRules(rules);
  }

  static void setBlockTags(List<String> tags) {
    final rules = getTagRules();
    rules['block'] = tags;
    setTagRules(rules);
  }

  // --- custom tags ---
  static List<String> getCustomTags() {
    final s = _read(_kCustomTags);
    if (s.isEmpty) return [];
    try {
      final list = jsonDecode(s);
      if (list is List) return list.cast<String>();
    } catch (_) {}
    return [];
  }

  static void setCustomTags(List<String> tags) {
    _write(_kCustomTags, jsonEncode(tags));
  }
}
