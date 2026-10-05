// 标签推荐的排序规则测试（纯函数，不发请求、不依赖 Flutter 渲染）。
//
// 这里是本功能的**唯一判据**：推荐下拉的正确性全在
// [rankTagSuggestions] 的排序键上，而排序键一旦写错，症状是「推荐里
// 没有我想点的那个」——一种在 UI 上很难被肉眼抓住的错误，所以必须用
// 断言把顺序钉死。
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/models/user.dart';
import 'package:twitter_pic_flutter/widgets/tag_suggestions.dart';

/// 造一张标签表。[counts] 是 `标签名 → 票数`。
List<TagCount> cloud(Map<String, int> counts) => counts.entries
    .map((e) => TagCount(tag: e.key, count: e.value))
    .toList();

void main() {
  // 线上真实标签表的一小片（实测 /api/tag-cloud?limit=500 → 178 个标签）。
  final real = cloud(const {
    '女性': 7580,
    '男女性交': 1554,
    '二次元': 1456,
    '露奶': 1200,
    '自拍': 1196,
    '男性': 936,
    '男娘': 762,
    '原创': 721,
    'COS': 620,
  });

  group('空输入不退化成热门推荐', () {
    test('空串返回空列表——不替调用方决定弹热门', () {
      expect(rankTagSuggestions(real, ''), isEmpty);
      expect(rankTagSuggestions(real, '   '), isEmpty);
    });

    test('null 语义不出现：返回类型是 List<TagCount>，空即空列表', () {
      // 调用方用 `.isEmpty` 判「要不要弹」，所以必须返回真列表而不是 null。
      expect(rankTagSuggestions(real, '').runtimeType.toString(),
          isNot(contains('Null')));
    });
  });

  group('前缀命中', () {
    test('打「女」→ 女性 排第一，且排在子串命中的 男女性交 前面', () {
      final got = rankTagSuggestions(real, '女');
      expect(got, isNotEmpty);
      expect(got.first.tag, '女性');
      // 「男女性交」也含「女」，但它不是前缀命中，必须排在其后。
      final idxN = got.indexWhere((e) => e.tag == '男女性交');
      if (idxN >= 0) expect(idxN, greaterThan(0));
    });

    test('前缀命中内部按热度降序', () {
      // 造两个同前缀、同位置、不同热度，必须按热度排。
      final c = cloud(const {'女A': 10, '女B': 99, '女C': 50});
      final got = rankTagSuggestions(c, '女');
      expect(got.map((e) => e.tag).toList(), ['女B', '女C', '女A']);
    });

    test('打「二」→ 二次元', () {
      expect(rankTagSuggestions(real, '二').first.tag, '二次元');
    });

    test('大小写不敏感：打「cos」能命中 COS', () {
      final got = rankTagSuggestions(real, 'cos');
      expect(got.map((e) => e.tag), contains('COS'));
    });
  });

  group('子串命中（不是前缀）', () {
    test('打「性」→ 命中含「性」的标签，按匹配位置排序', () {
      final got = rankTagSuggestions(real, '性');
      final tags = got.map((e) => e.tag).toList();
      expect(tags, containsAll(<String>['女性', '男性', '男女性交']));
      // 位置更靠前的排更前：女性(index1) 应当在 男女性交(index3) 之前。
      expect(
        tags.indexOf('女性'),
        lessThan(tags.indexOf('男女性交')),
        reason: '女性 的「性」在 index1，男女性交 的「性」在 index3',
      );
    });

    test('没有任何标签命中时返回空列表（不是 null、不是全表）', () {
      final got = rankTagSuggestions(real, 'zzz不存在');
      expect(got, isEmpty);
    });
  });

  group('稳定性与上限', () {
    test('同样的输入两次调用，顺序完全一致', () {
      final a = rankTagSuggestions(real, '女').map((e) => e.tag).toList();
      final b = rankTagSuggestions(real, '女').map((e) => e.tag).toList();
      expect(a, b);
    });

    test('默认最多 kTagSuggestLimit 条', () {
      final many = cloud({for (var i = 0; i < 50; i++) '标$i': i + 1});
      final got = rankTagSuggestions(many, '标');
      expect(got.length, kTagSuggestLimit);
      expect(got.length, lessThanOrEqualTo(kTagSuggestLimit));
    });

    test('limit 可覆盖，且 limit<=0 返回空', () {
      final many = cloud({for (var i = 0; i < 20; i++) '标$i': i + 1});
      expect(rankTagSuggestions(many, '标', limit: 3).length, 3);
      expect(rankTagSuggestions(many, '标', limit: 0), isEmpty);
      expect(rankTagSuggestions(many, '标', limit: -1), isEmpty);
    });

    test('热度相同则按标签名升序（保证稳定，不靠 map 迭代顺序）', () {
      final c = cloud(const {'甲标': 5, '乙标': 5, '丙标': 5});
      final got = rankTagSuggestions(c, '标');
      expect(got.map((e) => e.tag).toList(), ['丙标', '乙标', '甲标']);
    });
  });

  group('与线上真实标签表对照', () {
    test('打「女」在前 3 条里能找到女性和男女性交', () {
      final got = rankTagSuggestions(real, '女').map((e) => e.tag).toList();
      expect(got.take(3), contains('女性'));
      expect(got.take(3), contains('男女性交'));
    });

    test('打「奶」能命中 露奶（跨位置子串：裸标签不含该字，含「奶」字）', () {
      // 注意这里必须用「奶」而不是「乳」——「露奶」里没有「乳」字。
      // 写错一个字会让这条断言以「假绿」的方式通过，所以钉死真实标签。
      final got = rankTagSuggestions(real, '奶').map((e) => e.tag).toList();
      expect(got, contains('露奶'));
      expect(rankTagSuggestions(real, '乳'), isEmpty,
          reason: '真实标签表里没有任何标签含「乳」字');
    });
  });
}